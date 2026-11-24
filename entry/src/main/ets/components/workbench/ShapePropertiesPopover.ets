import { COLORS } from '../../common/constants';
import { WorkbenchIcon } from './WorkbenchIcon';
import { FONT_MONO } from '../../common/Fonts';
import { UI } from '../../common/UiTokens';
import { canvasKeyName } from '../../common/CanvasKeyboard';
import { resetModifierKeys, isCtrlHeld, isShiftHeld } from '../../common/ModifierKeys';
import { LayerGroup, UiLayer } from '../../common/types';
import { Shape, ShapeType, ShapeBounds, getShapeBounds, getShapeArea } from '../../models/GdsiiData';
import { PropertyCellOption, ShapePropertyField, shapePropertyFields, shapePropertyValue } from '../../services/ShapePropertyService';
import { hongTuThemeState, Radius } from '../../store/ThemeStore';
import { MENU_ITEM_STYLE, menuCheckIcon, menuIcon, menuStyle, workbenchLuminousMenuOptions } from '../../common/WorkbenchMenuStyle';

/**
 * 图层外观与分组增量补丁（由属性检查器「图层属性」卡片实时提交）
 */
export interface InspectorLayerPatch {
  group?: LayerGroup;
  fillStyle?: string;
  transparency?: number;
}

interface LayerPurposeDef {
  group: LayerGroup;
  label: string;
}

interface InspectorInfoRow {
  label: string;
  value: string;
  highlightValue: boolean;
}

const LAYER_PURPOSES: LayerPurposeDef[] = [
  { group: LayerGroup.OTHER, label: '版图层' },
  { group: LayerGroup.INTERCONNECT, label: '互连层' },
  { group: LayerGroup.DOPING, label: '掺杂层' },
  { group: LayerGroup.CONTACT, label: '接触孔' },
];

function formatUmFromNm(nm: number): string {
  if (!Number.isFinite(nm)) return '0.000';
  return (nm / 1000).toFixed(3);
}

function formatAreaUm2WithCommas(areaNm2: number): string {
  if (!Number.isFinite(areaNm2) || areaNm2 <= 0) return '0.000';
  const um2: number = areaNm2 / 1e6;
  const fixed: string = um2.toFixed(3);
  const dotIdx: number = fixed.indexOf('.');
  const intPart: string = dotIdx >= 0 ? fixed.substring(0, dotIdx) : fixed;
  const fracPart: string = dotIdx >= 0 ? fixed.substring(dotIdx) : '';
  let formattedInt: string = '';
  for (let i: number = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 === 0 && intPart[i - 1] !== '-') {
      formattedInt += ',';
    }
    formattedInt += intPart[i];
  }
  return `${formattedInt}${fracPart}`;
}

/**
 * 鸿图五卡片折叠式「属性检查器」（同时驱动画布就近悬浮面板与右侧常驻侧边栏）
 *
 * 五张结构化折叠卡片（悬浮窗与右侧边栏双端同构、状态实时互通）：
 * 1. 对象信息（对象类型、所属单元、图层色块与层索引、选择状态 + 实例/文本/线宽上下文编辑）
 * 2. 几何属性（边界框/中心点/对角切换，X / Y / 宽 / 高 微米 µm 实时直编，面积千分位 µm²）
 * 3. 阵列属性（卡片头开关 Toggle + 行数 / 列数 / 行距 µm / 列距 µm，支持 AREF 直编与普通选区一键阵列）
 * 4. 图层属性（目标图层、图层用途、实心填充/网格填充/线框 三态胶囊、不透明度 0~100% 滑块）
 * 5. 操作（复制 / 阵列 / 改层 + 合并 / 相减 / 相交 / 异或 双排快捷网格 + 删除按钮）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct ShapePropertiesPopover {
  @Prop @Watch('resetDraft') documentId: string = '';
  @Prop @Watch('resetDraft') revision: number = 0;
  @Prop selectedShape: Shape | null = null;
  @Prop @Watch('resetDraft') selectedShapes: Shape[] = [];
  @Prop layers: UiLayer[] = [];
  @Prop cells: PropertyCellOption[] = [];
  @Prop currentCellName: string = 'TOP';
  @Prop activeLayerNumber: number = 1;
  @Prop activeDatatype: number = 0;
  @Prop pinned: boolean = false;
  @Prop floatingEnabled: boolean = true;
  @Prop editable: boolean = true;
  @Prop panelHeight: number = 596;
  @Prop docked: boolean = false;
  @Prop allowEmptySelection: boolean = false;

  /** 坐标基准：1=边界框左下(X,Y+宽,高，对齐参考图默认), 0=中心点(CX,CY+宽,高), 2=对角边界(X1,Y1-X2,Y2) */
  @StorageLink('hongtuPropCoordMode') coordMode: number = 1;

  @State private infoExpanded: boolean = true;
  @State private geomExpanded: boolean = true;
  @State private arrayExpanded: boolean = true;
  @State private layerExpanded: boolean = true;
  @State private opsExpanded: boolean = true;
  @State private detailsExpanded: boolean = false;

  @State private batchArrayEnabled: boolean = true;
  @State private batchArrayRowsDraft: string = '1';
  @State private batchArrayColsDraft: string = '1';
  @State private batchArrayRowPitchUmDraft: string = '0.000';
  @State private batchArrayColPitchUmDraft: string = '0.000';

  @State propertiesDraft: string = '';
  @State errorText: string = '';
  private propertiesSelectionKey: string = '';
  private propertiesSourceValue: string = '';

  onShapePropertySubmit: (shapeId: number, property: string, value: string) => void = () => {};
  onPropertiesSubmit: ((ids: number[], property: string, value: string, documentId: string, revision: number) => string) | null = null;
  togglePinnedAction: () => void = () => {};
  toggleFloatingAction: (() => void) | null = null;
  closeAction: () => void = () => {};
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

  aboutToAppear(): void {
    if (this.coordMode !== 0 && this.coordMode !== 1 && this.coordMode !== 2) {
      this.coordMode = 1;
    }
    if (!this.docked) {
      // 悬浮窗默认精简展开核心卡片，侧边栏默认五卡全开，点击任一卡片头均可自由折叠/展开
      this.infoExpanded = true;
      this.geomExpanded = true;
      this.arrayExpanded = this.isSingleInstance();
      this.layerExpanded = true;
      this.opsExpanded = true;
    }
    this.resetDraft();
  }

  aboutToDisappear(): void {
    resetModifierKeys();
  }

  private focusGuardId(): string {
    return this.docked ? 'workbench-inspector-focus-guard' : 'shape-properties-focus-guard-floating';
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

  private hasTargets(): boolean {
    return this.targets().length > 0;
  }

  private canRunInspectorOperation(requiresMultiple: boolean): boolean {
    return this.editable && (requiresMultiple
      ? this.targets().length >= 2 && this.booleanAction !== null
      : this.hasTargets());
  }

  private selectionKey(): string {
    return `${this.documentId}:${this.revision}:` + this.targets().map((s: Shape) => s.id).join(',');
  }

  private commonType(): ShapeType | null {
    const targets: Shape[] = this.targets();
    return targets.length > 0 && targets.every((s: Shape) => s.type === targets[0].type) ? targets[0].type : null;
  }

  private isSingleInstance(): boolean {
    const targets: Shape[] = this.targets();
    return targets.length === 1 && targets[0].type === ShapeType.INSTANCE;
  }

  private typeLabel(): string {
    switch (this.commonType()) {
      case ShapeType.RECT: return '矩形';
      case ShapeType.POLYGON: return '多边形';
      case ShapeType.PATH: return '路径';
      case ShapeType.TEXT: return '文本';
      case ShapeType.INSTANCE: return '单元实例';
      default: return '图形';
    }
  }

  private headerTitleText(): string {
    if (this.docked) {
      return '属性检查器';
    }
    const targets: Shape[] = this.targets();
    if (targets.length === 1) {
      return `${this.typeLabel()} #${targets[0].id}`;
    }
    if (targets.length > 1) {
      return `属性 · ${targets.length} 个对象`;
    }
    return '属性检查器';
  }

  private objectTypeSummary(): string {
    const targets: Shape[] = this.targets();
    if (targets.length === 0) {
      return '未选中对象';
    }
    if (targets.length === 1) {
      return `${this.typeLabel()} (#${targets[0].id})`;
    }
    if (this.commonType() !== null) {
      return `多个${this.typeLabel()} (${targets.length})`;
    }
    return `多个图形 (${targets.length})`;
  }

  private commonValue(key: string): string {
    const targets: Shape[] = this.targets();
    if (targets.length === 0) return '';
    const value: string = shapePropertyValue(targets[0], key);
    return targets.every((s: Shape) => shapePropertyValue(s, key) === value) ? value : '';
  }

  private unionBounds(): ShapeBounds {
    const targets: Shape[] = this.targets();
    if (targets.length === 0) {
      return { minX: 0, minY: 0, maxX: 0, maxY: 0 };
    }
    let minX: number = Infinity;
    let minY: number = Infinity;
    let maxX: number = -Infinity;
    let maxY: number = -Infinity;
    for (let i: number = 0; i < targets.length; i++) {
      const b: ShapeBounds = getShapeBounds(targets[i]);
      if (b.minX < minX) minX = b.minX;
      if (b.minY < minY) minY = b.minY;
      if (b.maxX > maxX) maxX = b.maxX;
      if (b.maxY > maxY) maxY = b.maxY;
    }
    if (!Number.isFinite(minX) || !Number.isFinite(minY)) {
      return { minX: 0, minY: 0, maxX: 0, maxY: 0 };
    }
    return { minX: minX, minY: minY, maxX: maxX, maxY: maxY };
  }

  private totalAreaNm2(): number {
    const targets: Shape[] = this.targets();
    let sum: number = 0;
    for (let i: number = 0; i < targets.length; i++) {
      sum += getShapeArea(targets[i]);
    }
    return sum;
  }

  private geomNmDisplayValue(key: string): string {
    const targets: Shape[] = this.targets();
    if (targets.length === 0) return '0';
    const common: string = this.commonValue(key);
    if (common.length > 0) return common;
    const ub: ShapeBounds = this.unionBounds();
    switch (key) {
      case 'x':
      case 'minXEdge': return `${ub.minX}`;
      case 'y':
      case 'minYEdge': return `${ub.minY}`;
      case 'maxX': return `${ub.maxX}`;
      case 'maxY': return `${ub.maxY}`;
      case 'centerX': return `${(ub.minX + ub.maxX) * 0.5}`;
      case 'centerY': return `${(ub.minY + ub.maxY) * 0.5}`;
      case 'width':
      case 'widthCenter': return `${ub.maxX - ub.minX}`;
      case 'height':
      case 'heightCenter': return `${ub.maxY - ub.minY}`;
      default: return '0';
    }
  }

  resetDraft(): void {
    const key: string = this.selectionKey();
    const value: string = this.commonValue('properties');
    if (key === this.propertiesSelectionKey && value === this.propertiesSourceValue) return;
    this.propertiesDraft = value;
    this.propertiesSelectionKey = key;
    this.propertiesSourceValue = value;
    this.errorText = '';
    if (this.isSingleInstance()) {
      const inst: Shape = this.targets()[0];
      const cols: number = inst.arrayCols || 1;
      const rows: number = inst.arrayRows || 1;
      this.batchArrayEnabled = cols > 1 || rows > 1;
      this.batchArrayRowsDraft = `${rows}`;
      this.batchArrayColsDraft = `${cols}`;
      this.batchArrayRowPitchUmDraft = formatUmFromNm(inst.arrayRowStepY ?? 0);
      this.batchArrayColPitchUmDraft = formatUmFromNm(inst.arrayColStepX ?? 0);
      if (!this.docked && (cols > 1 || rows > 1)) {
        this.arrayExpanded = true;
      }
    } else {
      this.batchArrayRowsDraft = '1';
      this.batchArrayColsDraft = '1';
      this.batchArrayRowPitchUmDraft = '0.000';
      this.batchArrayColPitchUmDraft = '0.000';
    }
  }

  private fields(): ShapePropertyField[] {
    return shapePropertyFields(this.commonType());
  }

  private submit(key: string, value: string, selection: string): void {
    if (!this.editable || selection !== this.selectionKey()) return;
    const targets: Shape[] = this.targets();
    if (targets.length === 0) return;

    if (targets.length > 1 && this.commonValue(key).length === 0 && this.moveSelectedByAction !== null) {
      const targetNm: number = Number(value);
      if (Number.isFinite(targetNm)) {
        const ub: ShapeBounds = this.unionBounds();
        if (key === 'x' || key === 'minXEdge') {
          this.moveSelectedByAction(Math.round(targetNm - ub.minX), 0);
          this.errorText = '';
          return;
        }
        if (key === 'y' || key === 'minYEdge') {
          this.moveSelectedByAction(0, Math.round(targetNm - ub.minY));
          this.errorText = '';
          return;
        }
        if (key === 'centerX') {
          this.moveSelectedByAction(Math.round(targetNm - (ub.minX + ub.maxX) * 0.5), 0);
          this.errorText = '';
          return;
        }
        if (key === 'centerY') {
          this.moveSelectedByAction(0, Math.round(targetNm - (ub.minY + ub.maxY) * 0.5));
          this.errorText = '';
          return;
        }
      }
    }

    const ids: number[] = targets.map((s: Shape) => s.id);
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

  private inspectedLayer(): UiLayer | undefined {
    const targets: Shape[] = this.targets();
    if (targets.length > 0 && targets[0].type !== ShapeType.INSTANCE) {
      const ln: number = targets[0].layerNumber;
      const dt: number = targets[0].datatype;
      const found: UiLayer | undefined = this.layers.find((l: UiLayer) => l.layerNumber === ln && l.datatype === dt);
      if (found !== undefined) return found;
    }
    const active: UiLayer | undefined = this.layers.find(
      (l: UiLayer) => l.layerNumber === this.activeLayerNumber && l.datatype === this.activeDatatype
    );
    return active ?? (this.layers.length > 0 ? this.layers[0] : undefined);
  }

  private inspectedLayerIndex(): number {
    const target: UiLayer | undefined = this.inspectedLayer();
    if (target === undefined) return -1;
    return this.layers.findIndex((l: UiLayer) => l.layerNumber === target.layerNumber && l.datatype === target.datatype);
  }

  private formatLayerInspectorTag(layer: UiLayer): string {
    const code: string = layer.englishName.trim().length > 0 ? layer.englishName : `L${layer.layerNumber}`;
    const idxText: string = layer.datatype === 0 ? `${layer.layerNumber}` : `${layer.layerNumber}/${layer.datatype}`;
    return `${code} (层索引: ${idxText})`;
  }

  private layerOptions(): SelectOption[] {
    return this.layers.map((layer: UiLayer): SelectOption => ({
      value: this.formatLayerInspectorTag(layer)
    }));
  }

  private objectInfoLayerText(): string {
    const targets: Shape[] = this.targets();
    if (targets.length === 0) {
      const active: UiLayer | undefined = this.inspectedLayer();
      return active !== undefined ? this.formatLayerInspectorTag(active) : `L${this.activeLayerNumber}`;
    }
    if (targets.every((s: Shape) => s.type === ShapeType.INSTANCE)) {
      return '跨层单元实例';
    }
    const commonKey: string = this.commonValue('layerKey');
    if (commonKey.length > 0) {
      const matched: UiLayer | undefined = this.layers.find((l: UiLayer) => `${l.layerNumber}/${l.datatype}` === commonKey);
      if (matched !== undefined) {
        return this.formatLayerInspectorTag(matched);
      }
      return `L${commonKey}`;
    }
    const first: UiLayer | undefined = this.inspectedLayer();
    return first !== undefined ? `${this.formatLayerInspectorTag(first)} 等多层` : '多个图层';
  }

  private purposeOptions(): SelectOption[] {
    return LAYER_PURPOSES.map((p: LayerPurposeDef): SelectOption => ({ value: p.label }));
  }

  private currentPurposeIndex(): number {
    const layer: UiLayer | undefined = this.inspectedLayer();
    if (layer === undefined) return 0;
    const idx: number = LAYER_PURPOSES.findIndex((p: LayerPurposeDef) => p.group === layer.group);
    return idx >= 0 ? idx : 0;
  }

  private currentPurposeLabel(): string {
    return LAYER_PURPOSES[this.currentPurposeIndex()].label;
  }

  private currentFillStyleBucket(): 'solid' | 'cross' | 'outline' {
    const fs: string = this.inspectedLayer()?.fillStyle ?? 'solid';
    if (fs === 'outline' || fs === 'hollow') return 'outline';
    if (fs === 'cross' || fs === 'diagonal') return 'cross';
    return 'solid';
  }

  private currentOpacityPercent(): number {
    const transparency: number = this.inspectedLayer()?.transparency ?? 0;
    return Math.max(0, Math.min(100, Math.round(100 - transparency)));
  }

  private applyLayerPatch(patch: InspectorLayerPatch): void {
    const target: UiLayer | undefined = this.inspectedLayer();
    if (target === undefined || this.updateLayerStyleAction === null) return;
    this.updateLayerStyleAction(target.layerNumber, target.datatype, patch);
  }

  private coordModeShortLabel(): string {
    if (this.coordMode === 0) return '中心点';
    if (this.coordMode === 2) return '对角点';
    return '边界框';
  }

  private cycleCoordMode(): void {
    this.coordMode = this.coordMode === 1 ? 0 : (this.coordMode === 0 ? 2 : 1);
  }

  private triggerBatchArrayFromDraft(): void {
    const rows: number = Math.round(Number(this.batchArrayRowsDraft.trim()));
    const cols: number = Math.round(Number(this.batchArrayColsDraft.trim()));
    const rowPitchNm: number = Math.round(Number(this.batchArrayRowPitchUmDraft.trim()) * 1000);
    const colPitchNm: number = Math.round(Number(this.batchArrayColPitchUmDraft.trim()) * 1000);
    if (this.applyInlineArrayAction !== null &&
      Number.isInteger(rows) && Number.isInteger(cols) && rows >= 1 && cols >= 1 && (rows > 1 || cols > 1) &&
      Number.isFinite(rowPitchNm) && Number.isFinite(colPitchNm)) {
      if (this.applyInlineArrayAction(rows, cols, colPitchNm, rowPitchNm)) {
        this.errorText = '';
        return;
      }
    }
    if (this.openArrayAction !== null) {
      this.openArrayAction();
    }
  }

  @Builder
  private changeLayerQuickMenu() {
    Menu() {
      MenuItemGroup({ header: '更改选中对象所属图层' }) {
        ForEach(this.layers.slice(0, 28), (layer: UiLayer) => {
          MenuItem({
            content: `L${layer.layerNumber}/D${layer.datatype} ${layer.chineseName || layer.englishName}`,
            symbolStartIcon: menuIcon('layout'),
            symbolEndIcon: menuCheckIcon(
              this.commonValue('layerKey') === `${layer.layerNumber}/${layer.datatype}`
            )
          })
            .attributeModifier(MENU_ITEM_STYLE)
            .enabled(layer.locked !== true)
            .onClick(() => {
              if (this.changeSelectionLayerAction !== null) {
                this.changeSelectionLayerAction(layer.layerNumber, layer.datatype);
              } else {
                this.submit('layerKey', `${layer.layerNumber}/${layer.datatype}`, this.selectionKey());
              }
            })
        }, (layer: UiLayer): string => `insp_chg_${layer.layerNumber}_${layer.datatype}`)
      }
    }
    .attributeModifier(menuStyle(
      this.layers.slice(0, 28).map((layer: UiLayer): MenuItemOptions => ({
        content: `L${layer.layerNumber}/D${layer.datatype} ${layer.chineseName || layer.englishName}`,
        symbolStartIcon: menuIcon('layout')
      })),
      this.getUIContext()
    ))
  }

  @Builder
  private cardHeader(iconName: string, title: string, expanded: boolean, onToggle: () => void) {
    Row({ space: 7 }) {
      WorkbenchIcon({ name: iconName, iconSize: 14.5, color: COLORS.primary })
      Text(title)
        .fontSize(12.5)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLORS.ink)
        .layoutWeight(1)
      WorkbenchIcon({ name: expanded ? 'chevronUp' : 'chevronDown', iconSize: 12, color: COLORS.muted })
    }
    .width('100%')
    .height(34)
    .padding({ left: 10, right: 10 })
    .backgroundColor(COLORS.surfaceMuted)
    .border({
      width: { bottom: expanded ? 0.8 : 0 },
      color: COLORS.border
    })
    .alignItems(VerticalAlign.Center)
    .onClick(() => onToggle())
  }

  @Builder
  private infoKvRow(row: InspectorInfoRow) {
    Row({ space: 8 }) {
      Text(row.label)
        .fontSize(11.5)
        .fontColor(COLORS.muted)
        .width(62)
      Text(row.value)
        .fontSize(11.5)
        .fontWeight(row.highlightValue ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(COLORS.ink)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(24)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private umCoordField(prefix: string, key: string) {
    SelectionPropertyField({
      label: prefix,
      unit: 'µm',
      fieldKey: key,
      unitScale: 1000,
      decimals: 3,
      compactCell: true,
      bareInput: false,
      stacked: false,
      value: this.geomNmDisplayValue(key),
      selectionKey: this.selectionKey(),
      editable: this.editable && this.hasTargets() && (
        this.targets().length === 1 ||
        this.commonValue(key).length > 0 ||
        key === 'x' || key === 'y' || key === 'centerX' || key === 'centerY' || key === 'minXEdge' || key === 'minYEdge'
      ),
      focusGuardId: this.focusGuardId(),
      returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
      saveShortcutAction: this.saveShortcutAction,
      submitAction: (k: string, val: string, sel: string) => this.submit(k, val, sel)
    }).layoutWeight(1)
  }

  @Builder
  private fillStylePill(label: string, styleKey: 'solid' | 'cross' | 'outline') {
    Button(label, { type: ButtonType.Normal })
      .layoutWeight(1)
      .height(26)
      .padding({ left: 4, right: 4 })
      .fontSize(11)
      .fontWeight(this.currentFillStyleBucket() === styleKey ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.currentFillStyleBucket() === styleKey ? Color.White : COLORS.ink)
      .backgroundColor(this.currentFillStyleBucket() === styleKey ? COLORS.primary : COLORS.surfaceMuted)
      .border({
        width: 0.8,
        color: this.currentFillStyleBucket() === styleKey ? COLORS.primary : COLORS.border,
        radius: 6
      })
      .borderRadius(6)
      .focusable(false)
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        this.applyLayerPatch({ fillStyle: styleKey });
      })
  }

  @Builder
  private opGridButton(iconName: string, label: string, requiresMultiple: boolean, onTap: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        WorkbenchIcon({
          name: iconName,
          iconSize: 15.5,
          color: this.canRunInspectorOperation(requiresMultiple) ? COLORS.ink : COLORS.muted
        })
        Text(label)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.canRunInspectorOperation(requiresMultiple) ? COLORS.ink : COLORS.muted)
          .maxLines(1)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .height(48)
    .padding(0)
    .backgroundColor(COLORS.surface)
    .border({ width: 0.8, color: COLORS.border, radius: UI.controlRadius })
    .borderRadius(UI.controlRadius)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .enabled(this.canRunInspectorOperation(requiresMultiple))
    .opacity(this.canRunInspectorOperation(requiresMultiple) ? 1 : 0.42)
    .focusable(false)
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText(label)
    .bindTips(label)
    .onClick(() => {
      if (this.canRunInspectorOperation(requiresMultiple)) onTap();
    })
  }

  @Builder
  private ObjectInfoCard() {
    Column() {
      this.cardHeader('cell', '对象信息', this.infoExpanded, () => {
        this.infoExpanded = !this.infoExpanded;
      })
      if (this.infoExpanded) {
        Column({ space: 5 }) {
          this.infoKvRow({ label: '对象类型', value: this.objectTypeSummary(), highlightValue: true })
          this.infoKvRow({
            label: '所属单元',
            value: this.currentCellName.length > 0 ? this.currentCellName : 'TOP',
            highlightValue: true
          })

          Row({ space: 8 }) {
            Text('图层')
              .fontSize(11.5)
              .fontColor(COLORS.muted)
              .width(62)
            Row({ space: 6 }) {
              Row()
                .width(11)
                .height(11)
                .borderRadius(2.5)
                .backgroundColor(this.inspectedLayer()?.color ?? COLORS.primary)
                .border({ width: 0.6, color: COLORS.border })
              Text(this.objectInfoLayerText())
                .fontSize(11.5)
                .fontWeight(FontWeight.Medium)
                .fontColor(COLORS.ink)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .layoutWeight(1)
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .height(24)
          .alignItems(VerticalAlign.Center)

          this.infoKvRow({
            label: '选择状态',
            value: this.hasTargets() ? (this.editable ? '已选中' : '已选中 · 只读') : '未选中（点击画布选择）',
            highlightValue: this.hasTargets()
          })

          if (this.commonType() === ShapeType.INSTANCE) {
            Row({ space: 6 }) {
              Text('引用单元')
                .fontSize(11)
                .fontColor(COLORS.muted)
                .width(62)
              Select(this.cellOptions())
                .selected(this.cellIndex())
                .value(this.cellIndex() >= 0 ? this.cells[this.cellIndex()].name : '选择 Cell')
                .layoutWeight(1)
                .height(30)
                .font({ size: 11.5 })
                .fontColor(COLORS.ink)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 0.8, color: COLORS.border })
                .borderRadius(6)
                .enabled(this.editable)
                .focusable(false)
                .onSelect((index: number) => {
                  if (index >= 0 && index < this.cells.length) {
                    this.submit('cellId', `${this.cells[index].id}`, this.selectionKey());
                  }
                })
            }
            .width('100%')
            .margin({ top: 2 })
            .alignItems(VerticalAlign.Center)

            if (this.enterInstanceAction !== null || this.flattenInstanceAction !== null) {
              Row({ space: 6 }) {
                if (this.enterInstanceAction !== null && this.targets().length === 1) {
                  Button('进入子单元', { type: ButtonType.Normal })
                    .layoutWeight(1)
                    .height(28)
                    .fontSize(11)
                    .fontColor(COLORS.primary)
                    .backgroundColor(COLORS.primarySoft)
                    .border({ width: 0.8, color: COLORS.primary, radius: 6 })
                    .borderRadius(6)
                    .focusable(false)
                    .onClick(() => {
                      if (this.enterInstanceAction !== null) this.enterInstanceAction();
                    })
                }
                if (this.flattenInstanceAction !== null) {
                  Button('展开打平', { type: ButtonType.Normal })
                    .layoutWeight(1)
                    .height(28)
                    .fontSize(11)
                    .fontColor(COLORS.ink)
                    .backgroundColor(COLORS.surfaceMuted)
                    .border({ width: 0.8, color: COLORS.border, radius: 6 })
                    .borderRadius(6)
                    .enabled(this.editable)
                    .focusable(false)
                    .onClick(() => {
                      if (this.flattenInstanceAction !== null) this.flattenInstanceAction();
                    })
                }
              }.width('100%').margin({ top: 2 })
            }
          }

          if (this.commonType() === ShapeType.TEXT) {
            SelectionPropertyField({
              label: '文本内容',
              unit: '',
              fieldKey: 'text',
              compactCell: false,
              bareInput: false,
              stacked: false,
              value: this.commonValue('text'),
              selectionKey: this.selectionKey(),
              editable: this.editable,
              focusGuardId: this.focusGuardId(),
              returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
              saveShortcutAction: this.saveShortcutAction,
              submitAction: (k: string, v: string, s: string) => this.submit(k, v, s)
            })
          }

          if (this.commonType() === ShapeType.PATH) {
            SelectionPropertyField({
              label: '线宽',
              unit: 'µm',
              fieldKey: 'pathWidth',
              unitScale: 1000,
              decimals: 3,
              compactCell: false,
              bareInput: false,
              stacked: false,
              value: this.commonValue('pathWidth'),
              selectionKey: this.selectionKey(),
              editable: this.editable,
              focusGuardId: this.focusGuardId(),
              returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
              saveShortcutAction: this.saveShortcutAction,
              submitAction: (k: string, v: string, s: string) => this.submit(k, v, s)
            })
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 10 })
      }
    }
    .width('100%')
    .backgroundColor(COLORS.surface)
    .border({ width: 0.8, color: COLORS.border, radius: 10 })
    .borderRadius(10)
    .clip(true)
  }

  @Builder
  private GeometryCard() {
    Column() {
      this.cardHeader('rect', '几何属性', this.geomExpanded, () => {
        this.geomExpanded = !this.geomExpanded;
      })
      if (this.geomExpanded) {
        Column({ space: 7 }) {
          Row({ space: 6 }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 2 }) {
                Text(this.coordModeShortLabel())
                  .fontSize(11)
                  .fontColor(COLORS.muted)
                WorkbenchIcon({ name: 'chevronDown', iconSize: 9, color: COLORS.muted })
              }.alignItems(VerticalAlign.Center)
            }
            .width(48)
            .height(28)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .borderRadius(4)
            .focusable(false)
            .bindTips('点击切换坐标基准：边界框左下 / 中心点 / 对角点')
            .onClick(() => this.cycleCoordMode())

            if (this.coordMode === 0) {
              this.umCoordField('CX', 'centerX')
              this.umCoordField('CY', 'centerY')
            } else if (this.coordMode === 2) {
              this.umCoordField('X1', 'minXEdge')
              this.umCoordField('Y1', 'minYEdge')
            } else {
              this.umCoordField('X', 'x')
              this.umCoordField('Y', 'y')
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: 6 }) {
            Text(this.coordMode === 2 ? '对角' : '尺寸')
              .fontSize(11)
              .fontColor(COLORS.muted)
              .width(48)

            if (this.coordMode === 0) {
              this.umCoordField('宽', 'widthCenter')
              this.umCoordField('高', 'heightCenter')
            } else if (this.coordMode === 2) {
              this.umCoordField('X2', 'maxX')
              this.umCoordField('Y2', 'maxY')
            } else {
              this.umCoordField('宽', 'width')
              this.umCoordField('高', 'height')
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Row({ space: 6 }) {
            Text('面积')
              .fontSize(11.5)
              .fontColor(COLORS.muted)
              .width(48)
            Text(`${formatAreaUm2WithCommas(this.totalAreaNm2())} µm²`)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontFamily(FONT_MONO)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
              .maxLines(1)
          }
          .width('100%')
          .height(24)
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 10 })
      }
    }
    .width('100%')
    .backgroundColor(COLORS.surface)
    .border({ width: 0.8, color: COLORS.border, radius: 10 })
    .borderRadius(10)
    .clip(true)
  }

  @Builder
  private ArrayCard() {
    Column() {
      Row({ space: 7 }) {
        WorkbenchIcon({ name: 'layout', iconSize: 14.5, color: COLORS.primary })
        Text('阵列属性')
          .fontSize(12.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
          .onClick(() => { this.arrayExpanded = !this.arrayExpanded; })
        Toggle({ type: ToggleType.Switch, isOn: this.batchArrayEnabled })
          .selectedColor(COLORS.primary)
          .height(22)
          .enabled(this.editable)
          .onChange((isOn: boolean) => {
            if (isOn === this.batchArrayEnabled) return;
            this.batchArrayEnabled = isOn;
            if (isOn) {
              this.arrayExpanded = true;
            } else if (this.isSingleInstance()) {
              this.submit('arrayRows', '1', this.selectionKey());
              this.submit('arrayCols', '1', this.selectionKey());
            }
          })
      }
      .width('100%')
      .height(34)
      .padding({ left: 10, right: 10 })
      .backgroundColor(COLORS.surfaceMuted)
      .border({
        width: { bottom: this.arrayExpanded ? 0.8 : 0 },
        color: COLORS.border
      })
      .alignItems(VerticalAlign.Center)

      if (this.arrayExpanded) {
        if (this.isSingleInstance()) {
          Column({ space: 7 }) {
            Row({ space: 8 }) {
              Text('行数').fontSize(11).fontColor(COLORS.muted).width(32)
              SelectionPropertyField({
                label: '',
                unit: '',
                fieldKey: 'arrayRows',
                compactCell: true,
                bareInput: false,
                stacked: false,
                value: this.commonValue('arrayRows'),
                selectionKey: this.selectionKey(),
                editable: this.editable && this.batchArrayEnabled,
                focusGuardId: this.focusGuardId(),
                returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
                saveShortcutAction: this.saveShortcutAction,
                submitAction: (k: string, v: string, s: string) => this.submit(k, v, s)
              }).layoutWeight(1)

              Text('列数').fontSize(11).fontColor(COLORS.muted).width(32)
              SelectionPropertyField({
                label: '',
                unit: '',
                fieldKey: 'arrayCols',
                compactCell: true,
                bareInput: false,
                stacked: false,
                value: this.commonValue('arrayCols'),
                selectionKey: this.selectionKey(),
                editable: this.editable && this.batchArrayEnabled,
                focusGuardId: this.focusGuardId(),
                returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
                saveShortcutAction: this.saveShortcutAction,
                submitAction: (k: string, v: string, s: string) => this.submit(k, v, s)
              }).layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Center)

            Row({ space: 8 }) {
              Text('行距').fontSize(11).fontColor(COLORS.muted).width(32)
              SelectionPropertyField({
                label: '',
                unit: 'µm',
                fieldKey: 'arrayRowStepY',
                unitScale: 1000,
                decimals: 3,
                compactCell: true,
                bareInput: false,
                stacked: false,
                value: this.commonValue('arrayRowStepY'),
                selectionKey: this.selectionKey(),
                editable: this.editable && this.batchArrayEnabled,
                focusGuardId: this.focusGuardId(),
                returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
                saveShortcutAction: this.saveShortcutAction,
                submitAction: (k: string, v: string, s: string) => this.submit(k, v, s)
              }).layoutWeight(1)

              Text('列距').fontSize(11).fontColor(COLORS.muted).width(32)
              SelectionPropertyField({
                label: '',
                unit: 'µm',
                fieldKey: 'arrayColStepX',
                unitScale: 1000,
                decimals: 3,
                compactCell: true,
                bareInput: false,
                stacked: false,
                value: this.commonValue('arrayColStepX'),
                selectionKey: this.selectionKey(),
                editable: this.editable && this.batchArrayEnabled,
                focusGuardId: this.focusGuardId(),
                returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
                saveShortcutAction: this.saveShortcutAction,
                submitAction: (k: string, v: string, s: string) => this.submit(k, v, s)
              }).layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 10 })
        } else {
          Column({ space: 7 }) {
            Row({ space: 8 }) {
              Text('行数').fontSize(11).fontColor(COLORS.muted).width(32)
              TextInput({ text: this.batchArrayRowsDraft })
                .layoutWeight(1)
                .height(28)
                .fontSize(11.5)
                .fontFamily(FONT_MONO)
                .fontColor(COLORS.ink)
                .padding({ left: 7, right: 7 })
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 0.8, color: COLORS.border, radius: 6 })
                .borderRadius(6)
                .enabled(this.editable && this.batchArrayEnabled && this.hasTargets())
                .onFocus(() => resetModifierKeys())
                .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                .onChange((val: string) => { this.batchArrayRowsDraft = val; })

              Text('列数').fontSize(11).fontColor(COLORS.muted).width(32)
              TextInput({ text: this.batchArrayColsDraft })
                .layoutWeight(1)
                .height(28)
                .fontSize(11.5)
                .fontFamily(FONT_MONO)
                .fontColor(COLORS.ink)
                .padding({ left: 7, right: 7 })
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 0.8, color: COLORS.border, radius: 6 })
                .borderRadius(6)
                .enabled(this.editable && this.batchArrayEnabled && this.hasTargets())
                .onFocus(() => resetModifierKeys())
                .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                .onChange((val: string) => { this.batchArrayColsDraft = val; })
            }.width('100%').alignItems(VerticalAlign.Center)

            Row({ space: 8 }) {
              Text('行距').fontSize(11).fontColor(COLORS.muted).width(32)
              Row({ space: 3 }) {
                TextInput({ text: this.batchArrayRowPitchUmDraft })
                  .layoutWeight(1)
                  .height(26)
                  .fontSize(11.5)
                  .fontFamily(FONT_MONO)
                  .fontColor(COLORS.ink)
                  .padding({ left: 2, right: 2 })
                  .backgroundColor(Color.Transparent)
                  .borderWidth(0)
                  .enabled(this.editable && this.batchArrayEnabled && this.hasTargets())
                  .onFocus(() => resetModifierKeys())
                  .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                  .onChange((val: string) => { this.batchArrayRowPitchUmDraft = val; })
                Text('µm').fontSize(9.5).fontFamily(FONT_MONO).fontColor(COLORS.muted)
              }
              .layoutWeight(1)
              .height(28)
              .padding({ left: 6, right: 6 })
              .backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border, radius: 6 })
              .borderRadius(6)
              .alignItems(VerticalAlign.Center)

              Text('列距').fontSize(11).fontColor(COLORS.muted).width(32)
              Row({ space: 3 }) {
                TextInput({ text: this.batchArrayColPitchUmDraft })
                  .layoutWeight(1)
                  .height(26)
                  .fontSize(11.5)
                  .fontFamily(FONT_MONO)
                  .fontColor(COLORS.ink)
                  .padding({ left: 2, right: 2 })
                  .backgroundColor(Color.Transparent)
                  .borderWidth(0)
                  .enabled(this.editable && this.batchArrayEnabled && this.hasTargets())
                  .onFocus(() => resetModifierKeys())
                  .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                  .onChange((val: string) => { this.batchArrayColPitchUmDraft = val; })
                Text('µm').fontSize(9.5).fontFamily(FONT_MONO).fontColor(COLORS.muted)
              }
              .layoutWeight(1)
              .height(28)
              .padding({ left: 6, right: 6 })
              .backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border, radius: 6 })
              .borderRadius(6)
              .alignItems(VerticalAlign.Center)
            }.width('100%').alignItems(VerticalAlign.Center)

            if (this.hasTargets() && this.batchArrayEnabled &&
              (Number(this.batchArrayRowsDraft) > 1 || Number(this.batchArrayColsDraft) > 1)) {
              Button('执行行列阵列复制', { type: ButtonType.Normal })
                .width('100%')
                .height(28)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .backgroundColor(COLORS.primary)
                .borderRadius(6)
                .focusable(false)
                .enabled(this.editable)
                .onClick(() => this.triggerBatchArrayFromDraft())
            }
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 10 })
        }
      }
    }
    .width('100%')
    .backgroundColor(COLORS.surface)
    .border({ width: 0.8, color: COLORS.border, radius: 10 })
    .borderRadius(10)
    .clip(true)
  }

  @Builder
  private LayerPropertiesCard() {
    Column() {
      this.cardHeader('layers', '图层属性', this.layerExpanded, () => {
        this.layerExpanded = !this.layerExpanded;
      })
      if (this.layerExpanded) {
        Column({ space: 8 }) {
          if (this.layers.length > 0) {
            Row({ space: 6 }) {
              Text('目标图层')
                .fontSize(11.5)
                .fontColor(COLORS.muted)
                .width(54)
              Row({ space: 6 }) {
                Row()
                  .width(11)
                  .height(11)
                  .borderRadius(2.5)
                  .backgroundColor(this.inspectedLayer()?.color ?? COLORS.primary)
                  .border({ width: 0.6, color: COLORS.border })
                Select(this.layerOptions())
                  .selected(this.inspectedLayerIndex())
                  .value(this.inspectedLayer() !== undefined
                    ? this.formatLayerInspectorTag(this.inspectedLayer()!)
                    : `L${this.activeLayerNumber}`)
                  .layoutWeight(1)
                  .height(30)
                  .font({ size: 11.5 })
                  .fontColor(COLORS.ink)
                  .backgroundColor(Color.Transparent)
                  .borderRadius(6)
                  .enabled(this.editable)
                  .focusable(false)
                  .onSelect((index: number) => {
                    if (index >= 0 && index < this.layers.length) {
                      const chosen: UiLayer = this.layers[index];
                      if (this.hasTargets() && !this.targets().every((s: Shape) => s.type === ShapeType.INSTANCE)) {
                        if (this.changeSelectionLayerAction !== null) {
                          this.changeSelectionLayerAction(chosen.layerNumber, chosen.datatype);
                        } else {
                          this.submit('layerKey', `${chosen.layerNumber}/${chosen.datatype}`, this.selectionKey());
                        }
                      } else if (this.selectActiveLayerAction !== null) {
                        this.selectActiveLayerAction(chosen.layerNumber, chosen.datatype);
                      }
                    }
                  })
              }
              .layoutWeight(1)
              .height(30)
              .padding({ left: 8, right: 2 })
              .backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border, radius: 6 })
              .borderRadius(6)
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Row({ space: 6 }) {
              Text('图层用途')
                .fontSize(11.5)
                .fontColor(COLORS.muted)
                .width(54)
              Select(this.purposeOptions())
                .selected(this.currentPurposeIndex())
                .value(this.currentPurposeLabel())
                .layoutWeight(1)
                .height(30)
                .font({ size: 11.5 })
                .fontColor(COLORS.ink)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 0.8, color: COLORS.border, radius: 6 })
                .borderRadius(6)
                .focusable(false)
                .onSelect((index: number) => {
                  if (index >= 0 && index < LAYER_PURPOSES.length) {
                    this.applyLayerPatch({ group: LAYER_PURPOSES[index].group });
                  }
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Row({ space: 6 }) {
              Text('显示样式')
                .fontSize(11.5)
                .fontColor(COLORS.muted)
                .width(54)
              Row({ space: 4 }) {
                this.fillStylePill('实心填充', 'solid')
                this.fillStylePill('网格填充', 'cross')
                this.fillStylePill('线框', 'outline')
              }.layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Row({ space: 6 }) {
              Text('透明度')
                .fontSize(11.5)
                .fontColor(COLORS.muted)
                .width(54)
              Slider({
                value: this.currentOpacityPercent(),
                min: 0,
                max: 100,
                step: 1,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .blockSize({ width: 14, height: 14 })
                .trackThickness(4)
                .selectedColor(COLORS.primary)
                .blockColor(COLORS.primary)
                .trackColor(COLORS.border)
                .focusable(false)
                .onChange((val: number) => {
                  const nextTrans: number = Math.max(0, Math.min(100, Math.round(100 - val)));
                  this.applyLayerPatch({ transparency: nextTrans });
                })
              Text(`${this.currentOpacityPercent()}%`)
                .fontSize(11)
                .fontFamily(FONT_MONO)
                .fontColor(COLORS.ink)
                .textAlign(TextAlign.Center)
                .width(42)
                .height(24)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 0.8, color: COLORS.border, radius: 5 })
                .borderRadius(5)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 10 })
      }
    }
    .width('100%')
    .backgroundColor(COLORS.surface)
    .border({ width: 0.8, color: COLORS.border, radius: 10 })
    .borderRadius(10)
    .clip(true)
  }

  @Builder
  private OperationsCard() {
    Column() {
      this.cardHeader('bolt', '操作', this.opsExpanded, () => {
        this.opsExpanded = !this.opsExpanded;
      })
      if (this.opsExpanded) {
        Column({ space: 7 }) {
          Row({ space: 7 }) {
            this.opGridButton('copy', '复制', false, () => {
              if (this.duplicateAction !== null) {
                this.duplicateAction();
              } else {
                this.copyAction();
              }
            })
            this.opGridButton('layout', '阵列', false, () => {
              this.triggerBatchArrayFromDraft();
            })

            Button({ type: ButtonType.Normal }) {
              Column({ space: 4 }) {
                WorkbenchIcon({
                  name: 'layers',
                  iconSize: 15.5,
                  color: this.editable && this.hasTargets() ? COLORS.ink : COLORS.muted
                })
                Text('改层')
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.editable && this.hasTargets() ? COLORS.ink : COLORS.muted)
                  .maxLines(1)
              }
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
            }
            .layoutWeight(1)
            .height(48)
            .padding(0)
            .backgroundColor(COLORS.surface)
            .border({ width: 0.8, color: COLORS.border, radius: UI.controlRadius })
            .borderRadius(UI.controlRadius)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .enabled(this.editable && this.hasTargets())
            .opacity(this.editable && this.hasTargets() ? 1 : 0.42)
            .focusable(false)
            .hoverEffect(HoverEffect.Highlight)
            .bindTips('将选中对象移动到目标图层')
            .bindMenu(this.changeLayerQuickMenu, workbenchLuminousMenuOptions())
          }.width('100%')

          Row({ space: 7 }) {
            this.opGridButton('union', '合并', true, () => {
              if (this.booleanAction !== null) this.booleanAction('merge');
            })
            this.opGridButton('subtract', '相减', true, () => {
              if (this.booleanAction !== null) this.booleanAction('subtract');
            })
            this.opGridButton('intersect', '相交', true, () => {
              if (this.booleanAction !== null) this.booleanAction('intersect');
            })
            this.opGridButton('xor', '异或', true, () => {
              if (this.booleanAction !== null) this.booleanAction('xor');
            })
          }.width('100%')

          if (!this.docked && this.hasTargets()) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 5 }) {
                WorkbenchIcon({ name: 'delete', iconSize: 13.5, color: COLORS.danger })
                Text('删除选中对象').fontSize(11.5).fontWeight(FontWeight.Medium).fontColor(COLORS.danger)
              }.alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .height(30)
            .backgroundColor(COLORS.dangerSoft)
            .border({ width: 0.8, color: COLORS.dangerSoft, radius: 6 })
            .borderRadius(6)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .enabled(this.editable)
            .focusable(false)
            .onClick(this.deleteAction)
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 10 })
      }
    }
    .width('100%')
    .backgroundColor(COLORS.surface)
    .border({ width: 0.8, color: COLORS.border, radius: 10 })
    .borderRadius(10)
    .clip(true)
  }

  @Builder
  private AdvancedPropertiesSection() {
    if (this.hasTargets()) {
      Column({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            Text(this.detailsExpanded ? '收起高级与用户属性 (GDS Prop)' : '展开高级与用户属性 (GDS Prop)')
              .fontSize(11)
              .fontColor(COLORS.muted)
              .layoutWeight(1)
            WorkbenchIcon({ name: this.detailsExpanded ? 'chevronUp' : 'chevronDown', iconSize: 12, color: COLORS.muted })
          }.width('100%')
        }
        .width('100%')
        .height(28)
        .padding({ left: 10, right: 10 })
        .backgroundColor(COLORS.surface)
        .border({ width: 0.8, color: COLORS.border, radius: 8 })
        .borderRadius(8)
        .focusable(false)
        .onClick(() => {
          this.detailsExpanded = !this.detailsExpanded;
          this.resetDraft();
        })

        if (this.detailsExpanded) {
          Column({ space: 7 }) {
            if (this.commonType() === ShapeType.PATH) {
              ForEach(this.fields().filter((f: ShapePropertyField) =>
                ['pathType', 'pathBeginExtension', 'pathEndExtension', 'pathWidthAbsolute'].indexOf(f.key) >= 0),
                (field: ShapePropertyField) => {
                  SelectionPropertyField({
                    label: field.label,
                    unit: field.unit,
                    fieldKey: field.key,
                    compactCell: false,
                    bareInput: false,
                    stacked: false,
                    value: this.commonValue(field.key),
                    selectionKey: this.selectionKey(),
                    editable: this.editable,
                    focusGuardId: this.focusGuardId(),
                    returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
                    saveShortcutAction: this.saveShortcutAction,
                    submitAction: (k: string, v: string, s: string) => this.submit(k, v, s)
                  })
                }, (field: ShapePropertyField) => field.key)
            }

            if (this.commonType() === ShapeType.INSTANCE || this.commonType() === ShapeType.TEXT) {
              ForEach(this.fields().filter((f: ShapePropertyField) =>
                ['rotation', 'mirror', 'magnification', 'arrayColStepY', 'arrayRowStepX'].indexOf(f.key) >= 0),
                (field: ShapePropertyField) => {
                  SelectionPropertyField({
                    label: field.label,
                    unit: field.unit,
                    fieldKey: field.key,
                    compactCell: false,
                    bareInput: false,
                    stacked: false,
                    value: this.commonValue(field.key),
                    selectionKey: this.selectionKey(),
                    editable: this.editable,
                    focusGuardId: this.focusGuardId(),
                    returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
                    saveShortcutAction: this.saveShortcutAction,
                    submitAction: (k: string, v: string, s: string) => this.submit(k, v, s)
                  })
                }, (field: ShapePropertyField) => field.key)
            }

            Text('GDS/OASIS 用户属性记录 (JSON)')
              .fontSize(11)
              .fontColor(COLORS.muted)
              .width('100%')
            TextArea({ text: this.propertiesDraft, placeholder: '[{"attr":1,"dtype":6,"name":"","value":"备注"}]' })
              .height(78)
              .fontSize(11)
              .fontFamily(FONT_MONO)
              .fontColor(COLORS.ink)
              .backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border, radius: 6 })
              .borderRadius(6)
              .padding(8)
              .enabled(this.editable)
              .onFocus(() => { resetModifierKeys(); })
              .onChange((value: string) => {
                if (this.propertiesSelectionKey === this.selectionKey()) {
                  this.propertiesDraft = value;
                }
              })
              .onKeyEvent((event: KeyEvent) => {
                event.stopPropagation();
                const key: string = canvasKeyName(event.keyCode, event.keyText);
                let ctrl: boolean = isCtrlHeld();
                let shift: boolean = isShiftHeld();
                if (event.getModifierKeyState !== undefined) {
                  try {
                    ctrl = event.getModifierKeyState(['Ctrl']) || ctrl;
                    shift = event.getModifierKeyState(['Shift']) || shift;
                  } catch (_err) {}
                }
                if ((ctrl && key === 'S') || event.keyText === '\x13') {
                  if (event.type === KeyType.Down && this.saveShortcutAction !== null) {
                    this.saveShortcutAction(shift);
                  }
                  return;
                }
                if (event.type === KeyType.Down && key === 'ESCAPE') {
                  this.propertiesDraft = this.propertiesSourceValue;
                  this.parkFocusInsidePopover();
                }
              })
            Button('应用用户属性', { type: ButtonType.Normal })
              .width('100%')
              .height(28)
              .fontSize(11.5)
              .backgroundColor(COLORS.primary)
              .fontColor(Color.White)
              .borderRadius(6)
              .focusable(false)
              .enabled(this.editable && this.propertiesDraft.trim().length > 0)
              .onClick(() => this.submit('properties', this.propertiesDraft, this.propertiesSelectionKey))
          }
          .width('100%')
          .padding(10)
          .backgroundColor(COLORS.surface)
          .border({ width: 0.8, color: COLORS.border, radius: 10 })
          .borderRadius(10)
        }
      }.width('100%')
    }
  }

  build() {
    if (this.allowEmptySelection || this.hasTargets()) {
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

        // 顶部标题栏：侧边栏与画布悬浮窗各自拥有独立测试 ID，避免同时挂载冲突
        Row({ space: 6 }) {
          WorkbenchIcon({ name: 'layers', iconSize: 15.5, color: COLORS.primary })
          Text(this.headerTitleText())
            .fontSize(this.docked ? 13.5 : 13)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLORS.ink)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (!this.editable) {
            Text('只读')
              .fontSize(10)
              .fontColor(COLORS.muted)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(UI.chipRadius)
          }

          if (this.docked) {
            if (this.toggleFloatingAction !== null) {
              Button(this.floatingEnabled ? '悬浮开' : '悬浮关', { type: ButtonType.Normal })
                .height(24)
                .padding({ left: 7, right: 7 })
                .fontSize(10.5)
                .fontColor(this.floatingEnabled ? COLORS.primary : COLORS.muted)
                .backgroundColor(this.floatingEnabled ? COLORS.primarySoft : COLORS.surfaceMuted)
                .border({
                  width: 0.8,
                  color: this.floatingEnabled ? COLORS.primary : COLORS.border,
                  radius: 6
                })
                .borderRadius(6)
                .focusable(false)
                .bindTips('开启或关闭画布选中图形旁的悬浮属性窗')
                .onClick(() => {
                  if (this.toggleFloatingAction !== null) this.toggleFloatingAction();
                })
            }

            Button({ type: ButtonType.Normal }) {
              WorkbenchIcon({
                name: 'pin',
                iconSize: 14.5,
                color: COLORS.primary
              })
            }
            .id('sidebar-pin-properties-panel')
            .width(26)
            .height(26)
            .padding(0)
            .backgroundColor(COLORS.primarySoft)
            .border({ width: 0.8, color: COLORS.primary, radius: 6 })
            .borderRadius(6)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .hoverEffect(HoverEffect.Highlight)
            .accessibilityText('收起右侧属性检查器')
            .bindTips('收起右侧属性检查器（顶栏分栏按钮可随时重新展开）')
            .onClick(this.closeAction)
          } else {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 3 }) {
                WorkbenchIcon({
                  name: 'pin',
                  iconSize: 12.5,
                  color: this.pinned ? COLORS.primary : COLORS.muted
                })
                Text(this.pinned ? '已定角' : '跟随')
                  .fontSize(10.5)
                  .fontColor(this.pinned ? COLORS.primary : COLORS.muted)
              }.alignItems(VerticalAlign.Center)
            }
            .id('pin-properties-panel')
            .height(25)
            .padding({ left: 7, right: 7 })
            .backgroundColor(this.pinned ? COLORS.primarySoft : COLORS.surfaceMuted)
            .border({
              width: 0.8,
              color: this.pinned ? COLORS.primary : COLORS.border,
              radius: 6
            })
            .borderRadius(6)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .hoverEffect(HoverEffect.Highlight)
            .accessibilityText(this.pinned ? '取消固定悬浮窗位置' : '固定悬浮窗在画布右上角')
            .bindTips(this.pinned ? '当前固定于画布右上角（点击恢复跟随图形位置）' : '点击将悬浮属性窗固定于画布右上角')
            .onClick(this.togglePinnedAction)

            Button({ type: ButtonType.Circle }) {
              WorkbenchIcon({ name: 'close', iconSize: 12.5, color: COLORS.ink })
            }
            .width(25)
            .height(25)
            .padding(0)
            .borderRadius(Radius.pill)
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 0.8, color: COLORS.border })
            .focusable(false)
            .accessibilityText('关闭悬浮属性窗')
            .bindTips('暂时收起悬浮属性窗（右侧检查器保持常驻）')
            .onClick(this.closeAction)
          }
        }
        .width('100%')
        .height(this.docked ? 40 : 38)
        .padding({ left: 11, right: 9 })
        .backgroundColor(this.docked ? COLORS.surface : Color.Transparent)
        .border({ width: { bottom: 0.8 }, color: COLORS.border })
        .alignItems(VerticalAlign.Center)

        Scroll() {
          Column({ space: 8 }) {
            this.ObjectInfoCard()
            this.GeometryCard()
            this.ArrayCard()
            this.LayerPropertiesCard()
            this.OperationsCard()
            this.AdvancedPropertiesSection()

            if (this.errorText.length > 0) {
              Text(this.errorText)
                .fontSize(11)
                .fontColor(COLORS.danger)
                .width('100%')
                .padding({ left: 4, right: 4 })
            }
          }
          .width('100%')
          .padding({ left: 9, right: 9, top: 9, bottom: 11 })
        }
        .width('100%')
        .layoutWeight(this.docked ? 1 : 0)
        .constraintSize({
          minHeight: 0,
          maxHeight: this.docked ? undefined : Math.max(180, Math.min(480, this.panelHeight - 46))
        })
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .backgroundColor(this.docked && !hongTuThemeState.isLuminousBackgroundEnabled() ? COLORS.surfaceMuted : Color.Transparent)
        .clip(true)
      }
      .width(this.docked ? '100%' : 286)
      .height(this.docked ? '100%' : undefined)
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
  @Prop unitScale: number = 1;
  @Prop decimals: number = -1;
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

  private formatExternalToDisplay(rawVal: string): string {
    if (this.unitScale === 1 || rawVal.trim().length === 0) {
      return rawVal;
    }
    const num: number = Number(rawVal);
    if (!Number.isFinite(num)) {
      return rawVal;
    }
    const scaled: number = num / this.unitScale;
    return this.decimals >= 0 ? scaled.toFixed(this.decimals) : `${scaled}`;
  }

  private parseDraftToInternal(rawDraft: string): string {
    const trimmed: string = rawDraft.trim();
    if (this.unitScale === 1 || trimmed.length === 0) {
      return trimmed;
    }
    const num: number = Number(trimmed);
    if (!Number.isFinite(num)) {
      return trimmed;
    }
    return `${Math.round(num * this.unitScale)}`;
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
      this.draft = this.formatExternalToDisplay(this.value);
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
    this.submitAction(this.fieldKey, this.parseDraftToInternal(this.draft), this.focusedSelection);
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
    let ctrl: boolean = isCtrlHeld();
    let shift: boolean = isShiftHeld();
    if (event.getModifierKeyState !== undefined) {
      try {
        ctrl = event.getModifierKeyState(['Ctrl']) || ctrl;
        shift = event.getModifierKeyState(['Shift']) || shift;
      } catch (_err) {}
    }
    if ((ctrl && key === 'S') || event.keyText === '\x13') {
      event.stopPropagation();
      if (event.type === KeyType.Down) {
        this.commit();
        this.clearFocusedSelection();
        if (this.saveShortcutAction !== null) {
          this.saveShortcutAction(shift);
        }
        this.releaseToCanvasFocus();
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
    Row({ space: 3 }) {
      if (this.compactCell && this.label.length > 0) {
        Text(this.label)
          .fontSize(10.5)
          .fontColor(COLORS.muted)
          .constraintSize({ minWidth: 14 })
          .maxLines(1)
      }
      TextInput({ text: this.draft, placeholder: this.bareInput ? 'L/D' : '0.000' })
        .fontSize(11.5)
        .fontFamily(FONT_MONO)
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .height(26)
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
          .fontSize(9.5)
          .fontFamily(FONT_MONO)
          .fontColor(COLORS.muted)
          .maxLines(1)
      }
    }
    .width('100%')
    .height(28)
    .padding({ left: 6, right: 6 })
    .backgroundColor(COLORS.surfaceMuted)
    .border({ width: 0.8, color: COLORS.border, radius: 6 })
    .borderRadius(6)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    if (this.compactCell || this.bareInput) {
      this.inlineEmbeddedField()
    } else if (this.stacked) {
      Column({ space: 5 }) {
        Text(this.label).fontSize(11).fontColor(COLORS.muted).width('100%')
        this.inlineEmbeddedField()
      }.width('100%')
    } else {
      Row({ space: 6 }) {
        Text(this.label)
          .fontSize(11)
          .fontColor(COLORS.muted)
          .width(62)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          this.inlineEmbeddedField()
        }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Center)
    }
  }
}
