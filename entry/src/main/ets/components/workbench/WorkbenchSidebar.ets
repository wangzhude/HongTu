import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { UiLayer, LayerGroup } from '../../common/types';
import { COLORS } from '../../common/constants';
import { FONT_MONO } from '../../common/Fonts';
import { viewService } from '../../services/ViewService';
import { CellTreeNode } from './CellTreePanel';
import { WorkbenchIcon } from './WorkbenchIcon';
import { UI } from '../../common/UiTokens';
import { feedbackCurve, MOTION } from '../../common/Motion';
import { menuIcon, menuCheckIcon, menuStyle, MENU_ITEM_STYLE, MENU_DANGER_ITEM_STYLE } from '../../common/WorkbenchMenuStyle';
import { buildLuminousMenuOptions } from '../../store/LuminousSurfaceOptions';
import { hongTuThemeState } from '../../store/ThemeStore';
import { StableSegmentButton } from '../StableSegmentButton';
import { DrawnStatusIcon } from '../DrawnStatusIcon';

/**
 * 鸿图左侧全功能高密度工作台侧边栏（v8 四档切换 + 可拖拽动态分栏 + 完整图层/单元增删改查 + 快放面板版）
 *
 * 1. 顶部原生 4 档分段按钮：`分栏` | `图层` | `Cell` | `快放`（直接在左侧栏内完成参数化曲线/PCell/子单元点放与视图预设切换，无需弹窗挡画布）；
 * 2. 修复旧版 `Split` 模式下 Cell 列表被硬编码 `maxHeight: 148vp` 锁死的顽疾，改为可上下拖拽调节比例（默认 38:62，双击分隔条复位）的弹性 `layoutWeight` 双栏，100% 填满左侧垂直空间；
 * 3. 补齐完整图层生命周期操作：`+ 新层`、`清空本层图形`、`删除该图层（支持撤销）`、`一键清理全部空层`；
 * 4. 搜索框同时过滤 `Cell` 单元树与工艺掩膜层，并补齐一键打开「Cell 单元维护」入口。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

class ArrayDataSource<T> implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private items: T[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  private notifyDataReload(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  setData(items: T[]): void {
    const countChanged: boolean = this.items.length !== items.length;
    this.items = items;
    if (countChanged) this.notifyDataReload();
    for (let index = 0; index < this.items.length; index++) {
      for (let i = 0; i < this.listeners.length; i++) {
        this.listeners[i].onDataChange(index);
      }
    }
  }
}

/** 0=上下同屏分栏 (KLayout 默认), 1=仅工艺图层, 2=仅 Cell 单元, 3=快放与预设 */
enum SidebarLayoutMode {
  Split = 0,
  LayersOnly = 1,
  CellsOnly = 2,
  QuickStamp = 3,
}

interface QuickCurveStampItem {
  kind: string;
  label: string;
  desc: string;
}

const QUICK_CURVE_STAMPS: QuickCurveStampItem[] = [
  { kind: 'CIRCLE', label: '圆形晶胞', desc: '圆心拖拽或精确半径' },
  { kind: 'DONUT', label: '微环谐振腔', desc: '内外径同心圆环波导' },
  { kind: 'ELLIPSE', label: '椭圆结构', desc: '双半轴超表面单元' },
  { kind: 'ARC', label: '弯曲波导弧', desc: '任意起止角扇形/波导弧' }
];

@Component
export struct WorkbenchSidebar {
  @Prop @Watch('onLayerDataChanged') layers: UiLayer[] = [];
  @Prop @Watch('onLayerDataChanged') selectedLayerNumber: number = -1;
  @Prop @Watch('onLayerDataChanged') selectedDatatype: number = 0;
  @Prop sidebarWidth: number = 220;
  @Prop visible: boolean = true;
  @Prop showShortcutFooter: boolean = true;
  @Prop @Watch('onPresetNamesChanged') presetNames: string[] = [];
  @State selectedPresetName: string = '';

  @Prop cellTree: CellTreeNode[] = [];
  @Prop cellDefinitionCount: number = -1;
  /** 当前正在编辑的 Cell ID */
  @Prop currentTopCellId: number = 0;
  /** 文档主顶层 Root Top Cell ID（默认 0） */
  @Prop rootTopCellId: number = 0;
  @Prop currentEditingCellName: string = 'TOP';

  @State @Watch('onLayerDataChanged') searchKey: string = '';
  @State @Watch('onLayerDataChanged') nonEmptyOnly: boolean = false;
  @State private showSearchInput: boolean = false;
  @State private layoutMode: SidebarLayoutMode = SidebarLayoutMode.Split;
  @State private cellsCollapsed: boolean = false;
  /** 分栏模式下上栏 Cell 权重百分比（22~72，默认 38） */
  @State private cellsSplitWeight: number = 38;
  private dragStartWeight: number = 38;
  private sidebarBodyHeightVp: number = 560;
  private searchDebounceTimer: number = -1;

  private layerDataSource: ArrayDataSource<UiLayer> = new ArrayDataSource<UiLayer>();

  toggleLayerAction: (layerNumber: number, visible: boolean, datatype: number) => void = () => {};
  selectLayerAction: (layer: UiLayer) => void = () => {};
  styleLayerAction: (layer: UiLayer) => void = () => {};
  addLayerAction: () => void = () => {};
  clearLayerAction: (layerNumber: number, datatype: number) => void = (_ln: number, _dt: number) => {};
  deleteLayerAction: (layerNumber: number, datatype: number) => void = (_ln: number, _dt: number) => {};
  deleteEmptyLayersAction: () => void = () => {};
  openShortcutAction: () => void = () => {};
  setTopCellAction: (cellId: number, cellName: string) => void = () => {};
  newCellAction: () => void = () => {};
  placeCellInstanceAction: (cellId: number) => void = (_cellId: number) => {};
  deleteCellAction: (cellId: number) => void = () => {};
  renameCellAction: (cellId: number) => void = () => {};
  flattenCellAction: (cellId: number) => void = () => {};
  cellMaintenanceAction: () => void = () => {};
  openPCellAction: () => void = () => {};
  openCurveAction: (kind: string) => void = (_k: string) => {};
  makeCellFromSelectionAction: () => void = () => {};
  arrayCopySelectionAction: () => void = () => {};
  lockLayerAction: (layerNumber: number, datatype: number) => void = () => {};
  selectableLayerAction: (layerNumber: number, datatype: number, selectable: boolean) => void = () => {};
  selectAllOnLayerAction: (layerNumber: number, datatype: number) => void = () => {};
  importLypAction: () => void = () => {};
  exportLypAction: () => void = () => {};
  savePresetAction: () => void = () => {};
  applyPresetAction: (name: string) => void = () => {};
  deletePresetAction: (name: string) => void = () => {};

  aboutToAppear(): void {
    this.onPresetNamesChanged();
    PersistentStorage.persistProp('layerSearchKey', '');
    this.searchKey = AppStorage.get<string>('layerSearchKey') ?? '';
    if (this.searchKey.length > 0) {
      this.showSearchInput = true;
    }
    this.layerDataSource.setData(this.filteredLayers());
  }

  private onLayerDataChanged(): void {
    this.layerDataSource.setData(this.filteredLayers());
  }

  private onPresetNamesChanged(): void {
    if (!this.presetNames.includes(this.selectedPresetName)) this.selectedPresetName = this.presetNames[0] ?? '';
  }

  private layerRowKey(layer: UiLayer): string {
    return `${layer.layerNumber}:${layer.datatype}:${JSON.stringify(layer)}`;
  }

  private toggleLayerVisibility(layerNumber: number, datatype: number): void {
    let newVisible: boolean = false;
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].layerNumber === layerNumber && this.layers[i].datatype === datatype) {
        newVisible = !this.layers[i].visible;
        break;
      }
    }
    this.toggleLayerAction(layerNumber, newVisible, datatype);
    viewService.setCurrentLayerVisibility(layerNumber, newVisible, datatype);
  }

  private setAllLayersVisibility(visible: boolean): void {
    for (let i = 0; i < this.layers.length; i++) {
      const layer: UiLayer = this.layers[i];
      if (layer.visible !== visible) {
        this.toggleLayerAction(layer.layerNumber, visible, layer.datatype);
        viewService.setCurrentLayerVisibility(layer.layerNumber, visible, layer.datatype);
      }
    }
  }

  private visibleLayerCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].visible) n++;
    }
    return n;
  }

  private filteredLayers(): UiLayer[] {
    const key: string = this.searchKey.trim().toLowerCase();
    const result: UiLayer[] = [];
    for (let i = 0; i < this.layers.length; i++) {
      const layer: UiLayer = this.layers[i];
      const isSelected: boolean = layer.layerNumber === this.selectedLayerNumber && layer.datatype === this.selectedDatatype;
      if (this.nonEmptyOnly && layer.elementCount <= 0 && !isSelected) {
        continue;
      }
      if (key.length === 0 ||
        layer.chineseName.toLowerCase().includes(key) ||
        layer.englishName.toLowerCase().includes(key) ||
        `${layer.layerNumber}/${layer.datatype}`.includes(key)) {
        result.push(layer);
      }
    }
    return result;
  }

  private nodeMatchesSearch(node: CellTreeNode, key: string): boolean {
    if (key.length === 0) return true;
    if (node.cellName.toLowerCase().includes(key)) return true;
    for (let i = 0; i < node.children.length; i++) {
      if (this.nodeMatchesSearch(node.children[i], key)) return true;
    }
    return false;
  }

  private filteredCellRoots(): CellTreeNode[] {
    const key: string = this.searchKey.trim().toLowerCase();
    if (key.length === 0) return this.cellTree;
    return this.cellTree.filter((n: CellTreeNode): boolean => this.nodeMatchesSearch(n, key));
  }

  private collectPlaceableSubCells(): CellTreeNode[] {
    const seen: Set<number> = new Set<number>();
    const out: CellTreeNode[] = [];
    const stack: CellTreeNode[] = this.cellTree.slice();
    while (stack.length > 0) {
      const n: CellTreeNode | undefined = stack.shift();
      if (n !== undefined) {
        if (!seen.has(n.cellId) && n.cellId !== this.currentTopCellId) {
          seen.add(n.cellId);
          out.push(n);
        }
        for (let i = 0; i < n.children.length; i++) {
          stack.push(n.children[i]);
        }
      }
    }
    return out;
  }

  private buildLayoutModeItems(): SegmentButtonItemTuple {
    const items: [
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem
    ] = [
      { text: '分栏' },
      { text: '图层' },
      { text: '单元' },
      { text: '快放' }
    ];
    return items;
  }

  private activeCellDisplayName(): string {
    if (this.currentEditingCellName.length > 0) return this.currentEditingCellName;
    const stack: CellTreeNode[] = this.cellTree.slice();
    while (stack.length > 0) {
      const n: CellTreeNode | undefined = stack.pop();
      if (n !== undefined) {
        if (n.cellId === this.currentTopCellId) return n.cellName;
        for (let i = 0; i < n.children.length; i++) stack.push(n.children[i]);
      }
    }
    return 'TOP';
  }

  private rootTopCellName(): string {
    for (let i = 0; i < this.cellTree.length; i++) {
      if (this.cellTree[i].cellId === this.rootTopCellId) {
        return this.cellTree[i].cellName;
      }
    }
    return this.cellTree.length > 0 ? this.cellTree[0].cellName : 'TOP';
  }

  private isEditingSubCell(): boolean {
    return this.currentTopCellId !== this.rootTopCellId;
  }

  @Builder
  private tinyHeaderTextBtn(label: string, active: boolean, onTap: () => void) {
    Button(label, { type: ButtonType.Normal })
      .height(22)
      .fontSize(10)
      .padding({ left: 5, right: 5 })
      .fontColor(active ? COLORS.primary : COLORS.muted)
      .backgroundColor(active ? COLORS.primarySoft : Color.Transparent)
      .border({ width: active ? 0.8 : 0, color: active ? COLORS.primary : Color.Transparent })
      .borderRadius(5)
      .focusable(false)
      .onClick(() => onTap())
  }

  @Builder
  private buildSplitHandle() {
    Row({ space: 4 }) {
      Row()
        .width(28)
        .height(3)
        .borderRadius(2)
        .backgroundColor(COLORS.border)
    }
    .width('100%')
    .height(10)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .bindTips('上下拖动调整单元树与工艺层分栏高度比例（双击恢复默认）')
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 2 })
        .onActionStart(() => {
          this.dragStartWeight = this.cellsSplitWeight;
        })
        .onActionUpdate((event: GestureEvent) => {
          const totalH: number = Math.max(240, this.sidebarBodyHeightVp);
          const deltaPct: number = Math.round((event.offsetY / totalH) * 100);
          this.cellsSplitWeight = Math.min(72, Math.max(22, this.dragStartWeight + deltaPct));
        })
    )
    .gesture(
      TapGesture({ count: 2 })
        .onAction(() => {
          this.cellsSplitWeight = 38;
        })
    )
  }

  build() {
    Column({ space: 4 }) {
      // 紧凑顶栏：4 档切换（分栏 / 图层 / 单元 / 快放）+ 搜索 + 更多菜单
      Row({ space: 4 }) {
        Row() {
          StableSegmentButton({
            items: this.buildLayoutModeItems(),
            selectedIndex: this.layoutMode as number,
            onItemClicked: (idx: number) => {
              this.layoutMode = idx as SidebarLayoutMode;
              if (idx === SidebarLayoutMode.CellsOnly) {
                this.cellsCollapsed = false;
              }
            },
            fontColor: COLORS.muted,
            selectedFontColor: COLORS.primary,
            capsuleBackgroundColor: COLORS.surfaceMuted,
            selectedBackgroundColor: COLORS.primarySoft,
            fontSizeFp: 10.5,
            capsuleBorderRadius: 6,
            buttonMinHeight: 26,
            itemMinHeight: 22,
            itemPaddingHorizontal: 4,
            itemPaddingVertical: 2
          })
        }.layoutWeight(1)

        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({ name: 'search', iconSize: 14, color: (this.showSearchInput || this.searchKey.length > 0) ? COLORS.primary : COLORS.muted })
        }
        .width(26).height(26).padding(0)
        .backgroundColor((this.showSearchInput || this.searchKey.length > 0) ? COLORS.primarySoft : COLORS.surfaceMuted)
        .borderRadius(6).focusable(false)
        .accessibilityText('搜索过滤单元与图层')
        .bindTips('搜索单元名称、工艺层名称或层号')
        .onClick(() => {
          this.showSearchInput = !this.showSearchInput;
          if (!this.showSearchInput && this.searchKey.length > 0) {
            this.searchKey = '';
            AppStorage.setOrCreate<string>('layerSearchKey', '');
            this.onLayerDataChanged();
          }
        })

        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({ name: 'menu', iconSize: 14, color: COLORS.ink })
        }
        .id('layer-panel-menu')
        .width(26).height(26).padding(0)
        .backgroundColor(COLORS.surfaceMuted)
        .borderRadius(6).focusable(false)
        .accessibilityText('图层管理、预设与 LYP 菜单')
        .bindTips('新建/清理图层、导入导出 .lyp 与视图预设')
        .bindMenu(this.buildLypAndPresetMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
      }
      .width('100%')
      .height(30)
      .margin({ top: 4 })
      .alignItems(VerticalAlign.Center)

      if (this.showSearchInput && this.layoutMode !== SidebarLayoutMode.QuickStamp) {
        Search({ value: this.searchKey, placeholder: '搜 Cell 名、层名或 1/0…' })
          .width('100%')
          .height(28)
          .textFont({ size: 11.5 })
          .placeholderFont({ size: 11 })
          .fontColor(COLORS.ink)
          .placeholderColor(COLORS.muted)
          .searchIcon({ size: 13, color: COLORS.muted })
          .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 12, color: COLORS.muted } })
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 0.8, color: COLORS.border })
          .borderRadius(6)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation())
          .onChange((value: string) => {
            this.searchKey = value;
            AppStorage.setOrCreate<string>('layerSearchKey', value);
            if (this.searchDebounceTimer !== -1) {
              clearTimeout(this.searchDebounceTimer);
            }
            this.searchDebounceTimer = setTimeout(() => {
              this.onLayerDataChanged();
              this.searchDebounceTimer = -1;
            }, 100);
          })
      }

      // 主工作区容器（100% 弹性填满左侧栏高度）
      Column({ space: 2 }) {
        if (this.layoutMode === SidebarLayoutMode.QuickStamp) {
          this.buildQuickStampPane()
        } else {
          // ===== 上半栏：Cell 单元库与层级结构 =====
          if (this.layoutMode !== SidebarLayoutMode.LayersOnly) {
            this.buildCellsPane()
          }

          // 可拖拽比例分隔柄
          if (this.layoutMode === SidebarLayoutMode.Split && !this.cellsCollapsed) {
            this.buildSplitHandle()
          } else if (this.layoutMode === SidebarLayoutMode.Split) {
            Row().width('100%').height(0.8).backgroundColor(COLORS.border)
          }

          // ===== 下半栏：工艺掩膜图层 =====
          if (this.layoutMode !== SidebarLayoutMode.CellsOnly) {
            this.buildLayersPane()
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const h: number = Number(newArea.height);
        if (Number.isFinite(h) && h > 120) {
          this.sidebarBodyHeightVp = h;
        }
      })

      if (this.showShortcutFooter) {
        Button({ type: ButtonType.Normal }) {
          Row() {
            WorkbenchIcon({ name: 'keyboard', iconSize: 14, color: COLORS.primary })
            Text('快捷键与操作说明')
              .fontSize(11)
              .fontColor(COLORS.primary)
              .fontWeight(FontWeight.Medium)
              .margin({ left: 6 })
            Blank()
            Text('S·B·P·L·K·I')
              .fontSize(9)
              .fontColor(COLORS.muted)
              .fontFamily(FONT_MONO)
          }.width('100%')
        }
        .width('100%')
        .height(30)
        .padding({ left: 8, right: 8 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 0.8, color: COLORS.border })
        .borderRadius(6)
        .focusable(false)
        .onClick(() => this.openShortcutAction())
      }
    }
    .width(this.sidebarWidth)
    .height('100%')
    .padding({ left: 6, right: 6, bottom: 6 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { right: 0.8 }, color: COLORS.border })
  }

  @Builder
  private buildLypAndPresetMenu() {
    Menu() {
      MenuItemGroup({ header: '图层管理与清理' }) {
        MenuItem({ content: '新建工艺图层…', symbolStartIcon: menuIcon('new') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.addLayerAction())
        MenuItem({ content: '显示全部图层', symbolStartIcon: menuIcon('eye') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.setAllLayersVisibility(true))
        MenuItem({ content: '隐藏全部图层', symbolStartIcon: menuIcon('eyeOff') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.setAllLayersVisibility(false))
        MenuItem({ content: '仅显示有图形的层', symbolStartIcon: menuIcon('layer'),
          symbolEndIcon: menuCheckIcon(this.nonEmptyOnly) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.nonEmptyOnly)
          .onClick(() => { this.nonEmptyOnly = !this.nonEmptyOnly; })
        MenuItem({ content: '一键清理全部空图层', symbolStartIcon: menuIcon('delete', true) })
          .attributeModifier(MENU_DANGER_ITEM_STYLE)
          .onClick(() => this.deleteEmptyLayersAction())
      }
      MenuItemGroup({ header: '单元库维护' }) {
        MenuItem({ content: 'Cell 引用统计与清理孤立单元…', symbolStartIcon: menuIcon('cell') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.cellMaintenanceAction())
      }
      MenuItemGroup({ header: 'KLayout .lyp 图层配置' }) {
        MenuItem({ content: '导入 .lyp 图层属性…', symbolStartIcon: menuIcon('import') })
          .id('import-layer-profile')
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.importLypAction())
        MenuItem({ content: '导出 .lyp 图层属性…', symbolStartIcon: menuIcon('export') })
          .id('export-layer-profile')
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.exportLypAction())
      }
      MenuItemGroup({ header: '视图预设' }) {
        MenuItem({ content: '保存当前视图为预设…', symbolStartIcon: menuIcon('save') })
          .id('save-view-preset')
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.savePresetAction())
        if (this.presetNames.length > 0) {
          ForEach(this.presetNames, (pName: string) => {
            MenuItem({ content: `应用预设：${pName}`, symbolStartIcon: menuIcon('preset'),
              symbolEndIcon: menuCheckIcon(this.selectedPresetName === pName) })
              .attributeModifier(MENU_ITEM_STYLE)
              .onClick(() => {
                this.selectedPresetName = pName;
                this.applyPresetAction(pName);
              })
          }, (pName: string) => `preset_${pName}`)
          MenuItem({ content: `删除预设：${this.selectedPresetName}`, symbolStartIcon: menuIcon('delete', true) })
            .id('delete-view-preset')
            .attributeModifier(MENU_DANGER_ITEM_STYLE)
            .enabled(this.selectedPresetName.length > 0)
            .onClick(() => this.deletePresetAction(this.selectedPresetName))
        }
      }
    }
  }

  @Builder
  private buildQuickStampPane() {
    Scroll() {
      Column({ space: 10 }) {
        // 1. 参数化器件与几何快放
        Column({ space: 6 }) {
          Row() {
            Text('光子/版图几何快放')
              .fontSize(11.5)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
            Button('PCell 库', { type: ButtonType.Normal })
              .height(22).fontSize(10).padding({ left: 6, right: 6 })
              .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft).borderRadius(5).focusable(false)
              .onClick(() => this.openPCellAction())
          }.width('100%').alignItems(VerticalAlign.Center)

          ForEach(QUICK_CURVE_STAMPS, (item: QuickCurveStampItem) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                WorkbenchIcon({ name: 'sparkles', iconSize: 14, color: COLORS.primary })
                Column({ space: 1 }) {
                  Text(item.label).fontSize(11.5).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).maxLines(1)
                  Text(item.desc).fontSize(9.5).fontColor(COLORS.muted).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                WorkbenchIcon({ name: 'chevronRight', iconSize: 11, color: COLORS.muted })
              }.width('100%').alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .height(38)
            .padding({ left: 8, right: 8 })
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 0.8, color: COLORS.border })
            .borderRadius(6)
            .focusable(false)
            .onClick(() => this.openCurveAction(item.kind))
          }, (item: QuickCurveStampItem): string => item.kind)

          Row({ space: 6 }) {
            Button('选区成 Cell', { type: ButtonType.Normal })
              .height(28).fontSize(11).layoutWeight(1)
              .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border }).borderRadius(6).focusable(false)
              .onClick(() => this.makeCellFromSelectionAction())
            Button('阵列复制', { type: ButtonType.Normal })
              .height(28).fontSize(11).layoutWeight(1)
              .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft)
              .border({ width: 0.8, color: COLORS.primary }).borderRadius(6).focusable(false)
              .onClick(() => this.arrayCopySelectionAction())
          }.width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)

        Divider().color(COLORS.border)

        // 2. 子单元一键引用与排阵列
        Column({ space: 5 }) {
          Row() {
            Text(`可引用子单元 (${this.collectPlaceableSubCells().length})`)
              .fontSize(11.5)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
            Button('+ 新建 Cell', { type: ButtonType.Normal })
              .height(22).fontSize(10).padding({ left: 6, right: 6 })
              .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft).borderRadius(5).focusable(false)
              .onClick(() => this.newCellAction())
          }.width('100%').alignItems(VerticalAlign.Center)

          if (this.collectPlaceableSubCells().length === 0) {
            Text('当前库暂无可引用的其他子单元，点击上方「+ 新建 Cell」创建晶胞后即可在此一键点放或排 AREF 阵列。')
              .fontSize(10.5)
              .lineHeight(16)
              .fontColor(COLORS.muted)
              .padding(6)
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(6)
              .width('100%')
          } else {
            ForEach(this.collectPlaceableSubCells(), (sub: CellTreeNode) => {
              Row({ space: 6 }) {
                WorkbenchIcon({ name: 'cell', iconSize: 13, color: COLORS.primary })
                Text(sub.cellName)
                  .fontSize(11.5)
                  .fontFamily(FONT_MONO)
                  .fontColor(COLORS.ink)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Button('阵列/引用', { type: ButtonType.Normal })
                  .height(22).fontSize(10).padding({ left: 6, right: 6 })
                  .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft)
                  .borderRadius(4).focusable(false)
                  .onClick(() => this.placeCellInstanceAction(sub.cellId))
              }
              .width('100%')
              .height(30)
              .padding({ left: 6, right: 6 })
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(5)
              .alignItems(VerticalAlign.Center)
            }, (sub: CellTreeNode): string => `qsub_${sub.cellId}_${sub.cellName}`)
          }
        }.width('100%').alignItems(HorizontalAlign.Start)

        Divider().color(COLORS.border)

        // 3. 视图预设与 .lyp 快速切换
        Column({ space: 5 }) {
          Row() {
            Text('视图预设与 LYP')
              .fontSize(11.5)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
            Button('保存预设', { type: ButtonType.Normal })
              .height(22).fontSize(10).padding({ left: 6, right: 6 })
              .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border }).borderRadius(5).focusable(false)
              .onClick(() => this.savePresetAction())
          }.width('100%').alignItems(VerticalAlign.Center)

          ForEach(this.presetNames, (pName: string) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                WorkbenchIcon({ name: 'eye', iconSize: 13, color: this.selectedPresetName === pName ? COLORS.primary : COLORS.muted })
                Text(pName)
                  .fontSize(11)
                  .fontColor(this.selectedPresetName === pName ? COLORS.primary : COLORS.ink)
                  .layoutWeight(1)
                  .maxLines(1)
              }.width('100%').alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .height(28)
            .padding({ left: 8, right: 8 })
            .backgroundColor(this.selectedPresetName === pName ? COLORS.primarySoft : COLORS.surfaceMuted)
            .borderRadius(5)
            .focusable(false)
            .onClick(() => {
              this.selectedPresetName = pName;
              this.applyPresetAction(pName);
            })
          }, (pName: string): string => `qp_${pName}_${this.selectedPresetName}`)

          Row({ space: 6 }) {
            Button('导入 .lyp', { type: ButtonType.Normal })
              .height(26).fontSize(10.5).layoutWeight(1)
              .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border }).borderRadius(5).focusable(false)
              .onClick(() => this.importLypAction())
            Button('导出 .lyp', { type: ButtonType.Normal })
              .height(26).fontSize(10.5).layoutWeight(1)
              .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border }).borderRadius(5).focusable(false)
              .onClick(() => this.exportLypAction())
          }.width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ top: 2, bottom: 8 })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  @Builder
  private buildCellsPane() {
    Column({ space: 3 }) {
      // Cell 栏标题行（26vp）：支持折叠、+新建、放实例/阵列、单元维护
      Row({ space: 3 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 3 }) {
            WorkbenchIcon({
              name: this.cellsCollapsed && this.layoutMode === SidebarLayoutMode.Split ? 'chevronRight' : 'chevronDown',
              iconSize: 12,
              color: COLORS.muted
            })
            Text(`单元 (${this.countCells()})`)
              .fontSize(11.5)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.ink)
          }.alignItems(VerticalAlign.Center)
        }
        .height(24).padding({ left: 2, right: 4 }).backgroundColor(Color.Transparent).borderRadius(4).focusable(false)
        .onClick(() => {
          if (this.layoutMode === SidebarLayoutMode.Split) {
            this.cellsCollapsed = !this.cellsCollapsed;
          }
        })

        Blank()

        Button('+ 新建', { type: ButtonType.Normal })
          .height(22).fontSize(10).padding({ left: 5, right: 5 })
          .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft)
          .borderRadius(5).focusable(false)
          .bindTips('新建子单元 Cell 并自动切入该单元绘图')
          .onClick(() => this.newCellAction())

        Button('阵列', { type: ButtonType.Normal })
          .height(22).fontSize(10).padding({ left: 5, right: 5 })
          .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
          .border({ width: 0.8, color: COLORS.border }).borderRadius(5).focusable(false)
          .bindTips('在当前 Cell 中引用其他子 Cell 或排 Rows×Cols 行列阵列')
          .onClick(() => this.placeCellInstanceAction(-1))

        Button('维护', { type: ButtonType.Normal })
          .height(22).fontSize(10).padding({ left: 5, right: 5 })
          .fontColor(COLORS.muted).backgroundColor(Color.Transparent)
          .borderRadius(5).focusable(false)
          .bindTips('清理未引用孤立 Cell 与查看层级统计')
          .onClick(() => this.cellMaintenanceAction())
      }
      .width('100%')
      .height(26)
      .alignItems(VerticalAlign.Center)

      // 当前正在编辑的 Cell 醒目提示条
      Row({ space: 4 }) {
        Text('编辑中:')
          .fontSize(10)
          .fontColor(COLORS.muted)
        Text(this.activeCellDisplayName())
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontFamily(FONT_MONO)
          .fontColor(COLORS.primary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.isEditingSubCell() ? '子单元' : '顶层')
          .fontSize(9.5)
          .fontColor(this.isEditingSubCell() ? COLORS.accent : COLORS.primary)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .backgroundColor(COLORS.primarySoft)
          .borderRadius(4)
        if (this.isEditingSubCell()) {
          Button('回顶层', { type: ButtonType.Normal })
            .height(20).fontSize(10).padding({ left: 5, right: 5 })
            .fontColor(Color.White).backgroundColor(COLORS.primary)
            .borderRadius(4).focusable(false)
            .onClick(() => this.setTopCellAction(this.rootTopCellId, this.rootTopCellName()))
        }
      }
      .width('100%')
      .height(24)
      .padding({ left: 6, right: 4 })
      .backgroundColor(COLORS.surfaceMuted)
      .borderRadius(5)
      .alignItems(VerticalAlign.Center)

      if (!this.cellsCollapsed || this.layoutMode === SidebarLayoutMode.CellsOnly) {
        if (this.filteredCellRoots().length === 0) {
          Text(this.searchKey.trim().length > 0 ? '无匹配 Cell' : '暂无 Cell 定义')
            .fontSize(11)
            .fontColor(COLORS.muted)
            .padding({ top: 8, bottom: 8, left: 6 })
        } else {
          List() {
            ForEach(this.filteredCellRoots(), (node: CellTreeNode) => {
              this.buildCellNodeRow(node)
            }, (node: CellTreeNode) => this.cellRowKey(node))
          }
          .width('100%')
          .layoutWeight(1)
          .cachedCount(12)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .clip(true)
        }
      }
    }
    .width('100%')
    .layoutWeight(
      this.layoutMode === SidebarLayoutMode.CellsOnly
        ? 1
        : (this.cellsCollapsed ? 0 : this.cellsSplitWeight)
    )
  }

  @Builder
  private buildLayersPane() {
    Column({ space: 3 }) {
      // 图层栏紧凑标题与新建/全显/全隐/非空过滤行（26vp）
      Row({ space: 2 }) {
        Text(`工艺层 (${this.visibleLayerCount()}/${this.layers.length})`)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
          .maxLines(1)
        Button('+新层', { type: ButtonType.Normal })
          .height(21)
          .fontSize(10)
          .padding({ left: 5, right: 5 })
          .fontColor(COLORS.primary)
          .backgroundColor(COLORS.primarySoft)
          .borderRadius(4)
          .focusable(false)
          .bindTips('快速新建一个可用工艺层并设为当前绘图层')
          .onClick(() => this.addLayerAction())
        this.tinyHeaderTextBtn('全显', false, () => this.setAllLayersVisibility(true))
        this.tinyHeaderTextBtn('全隐', false, () => this.setAllLayersVisibility(false))
        this.tinyHeaderTextBtn('非空', this.nonEmptyOnly, () => { this.nonEmptyOnly = !this.nonEmptyOnly; })
      }
      .width('100%')
      .height(26)
      .alignItems(VerticalAlign.Center)

      List() {
        LazyForEach(this.layerDataSource, (layer: UiLayer) => {
          ListItem() {
            LayerToolboxRow({
              layer: layer,
              elementCount: layer.elementCount,
              isActive: layer.layerNumber === this.selectedLayerNumber && layer.datatype === this.selectedDatatype,
              toggleAction: (layerNumber: number, datatype: number) => {
                this.toggleLayerVisibility(layerNumber, datatype);
              },
              selectAction: (selectedLayer: UiLayer) => {
                this.selectLayerAction(selectedLayer);
              },
              styleLayerAction: (selectedLayer: UiLayer) => {
                this.styleLayerAction(selectedLayer);
              },
              lockAction: (layerNumber: number, datatype: number) => {
                this.lockLayerAction(layerNumber, datatype);
              },
              selectableAction: (layerNumber: number, datatype: number, selectable: boolean) => {
                this.selectableLayerAction(layerNumber, datatype, selectable);
              },
              selectAllOnLayerAction: (layerNumber: number, datatype: number) => {
                this.selectAllOnLayerAction(layerNumber, datatype);
              },
              clearLayerAction: (layerNumber: number, datatype: number) => {
                this.clearLayerAction(layerNumber, datatype);
              },
              deleteLayerAction: (layerNumber: number, datatype: number) => {
                this.deleteLayerAction(layerNumber, datatype);
              }
            })
          }
        }, (layer: UiLayer) => this.layerRowKey(layer))
      }
      .layoutWeight(1)
      .width('100%')
      .cachedCount(18)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)
    }
    .layoutWeight(
      this.layoutMode === SidebarLayoutMode.LayersOnly || this.cellsCollapsed
        ? 1
        : Math.max(25, 100 - this.cellsSplitWeight)
    )
    .width('100%')
  }

  private cellRowKey(node: CellTreeNode): string {
    return `${node.key()}:${node.cellName}:${node.referenceCount}:${node.expanded}:${node.children.length}:${this.currentTopCellId}:${this.rootTopCellId}:${this.searchKey}`;
  }

  private toggleCellExpanded(path: string): void {
    const pending: CellTreeNode[] = this.cellTree.slice();
    while (pending.length > 0) {
      const node: CellTreeNode = pending.pop()!;
      if (node.path === path) {
        if (node.children.length === 0) return;
        node.expanded = !node.expanded;
        this.cellTree = this.cellTree.slice();
        return;
      }
      for (const child of node.children) pending.push(child);
    }
  }

  private cellRowIndent(depth: number): number {
    return Math.min(depth * 12, Math.max(0, this.sidebarWidth - 150));
  }

  @Builder
  buildCellNodeRow(node: CellTreeNode) {
    ListItem() {
      Row({ space: 2 }) {
        Row().width(this.cellRowIndent(node.depth))

        if (node.children.length > 0) {
          Button({ type: ButtonType.Normal }) {
            WorkbenchIcon({
              name: node.expanded ? 'chevronDown' : 'chevronRight',
              iconSize: 11,
              color: COLORS.primary
            })
          }
          .width(18).height(24).padding(0).backgroundColor(Color.Transparent).borderRadius(4).focusable(false)
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onMouse((event: MouseEvent) => event.stopPropagation())
          .onClick(() => this.toggleCellExpanded(node.path))
        } else {
          Row().width(14)
        }

        DrawnStatusIcon({
          kind: node.cellId === this.currentTopCellId ? 'radio' : 'active',
          iconSize: 10,
          strokeColor: node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.muted,
          showSoftPlate: false
        })

        Text(node.cellName)
          .fontSize(11.5)
          .fontColor(node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.ink)
          .fontWeight(node.cellId === this.currentTopCellId ? FontWeight.Bold : FontWeight.Normal)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 3 })
          .bindTips(node.cellId === this.rootTopCellId ? `${node.cellName} (顶层主单元，双击切换)` : `${node.cellName} (双击进入编辑，点“引用”放置到当前 Cell)`)

        if (node.cellId === this.rootTopCellId && node.depth === 0) {
          Text('顶层')
            .fontSize(9)
            .fontColor(COLORS.primary)
            .padding({ left: 3, right: 3, top: 1, bottom: 1 })
            .backgroundColor(COLORS.primarySoft)
            .borderRadius(3)
        } else if (node.referenceCount > 0) {
          Text(`×${node.referenceCount}`)
            .fontSize(9.5)
            .fontColor(COLORS.muted)
            .fontFamily(FONT_MONO)
        } else {
          Text('待引用')
            .fontSize(9)
            .fontColor(COLORS.muted)
            .padding({ left: 3, right: 3, top: 1, bottom: 1 })
            .backgroundColor(COLORS.surfaceMuted)
            .borderRadius(3)
        }

        if (node.cellId !== this.currentTopCellId) {
          Button('引用', { type: ButtonType.Normal })
            .height(21).fontSize(10).padding({ left: 5, right: 5 })
            .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft)
            .borderRadius(4).focusable(false)
            .bindTips(`将 ${node.cellName} 作为实例或阵列放入当前编辑的 ${this.activeCellDisplayName()}`)
            .onTouch((event: TouchEvent) => event.stopPropagation())
            .onMouse((event: MouseEvent) => event.stopPropagation())
            .onClick(() => this.placeCellInstanceAction(node.cellId))
        }

        Button(node.cellId === this.currentTopCellId ? '当前' : '进入', { type: ButtonType.Normal })
          .height(21).fontSize(10).padding({ left: 5, right: 5 })
          .fontColor(node.cellId === this.currentTopCellId ? COLORS.muted : COLORS.ink)
          .backgroundColor(Color.Transparent)
          .borderRadius(4).focusable(false)
          .enabled(node.cellId !== this.currentTopCellId)
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onMouse((event: MouseEvent) => event.stopPropagation())
          .onClick(() => this.setTopCellAction(node.cellId, node.cellName))
      }
      .width('100%')
      .height(27)
      .padding({ left: 2, right: 4 })
      .borderRadius(5)
      .backgroundColor(node.cellId === this.currentTopCellId ? COLORS.primarySoft : Color.Transparent)
      .alignItems(VerticalAlign.Center)
      .gesture(
        TapGesture({ count: 2 })
          .onAction(() => {
            this.setTopCellAction(node.cellId, node.cellName);
          })
      )
      .bindContextMenu(this.buildCellContextMenu(node), ResponseType.RightClick,
        buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
      .bindContextMenu(this.buildCellContextMenu(node), ResponseType.LongPress,
        buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
    }

    if ((node.expanded || this.searchKey.trim().length > 0) && node.children.length > 0) {
      ForEach(
        node.children.filter((c: CellTreeNode): boolean => this.nodeMatchesSearch(c, this.searchKey.trim().toLowerCase())),
        (child: CellTreeNode) => {
          this.buildCellNodeRow(child)
        },
        (child: CellTreeNode) => this.cellRowKey(child)
      )
    }
  }

  @Builder
  buildCellContextMenu(node: CellTreeNode) {
    Menu() {
      MenuItemGroup() {
        MenuItem({ content: '进入编辑该 Cell', symbolStartIcon: menuIcon('cell'),
          symbolEndIcon: menuCheckIcon(node.cellId === this.currentTopCellId) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(node.cellId === this.currentTopCellId)
          .onClick(() => { this.setTopCellAction(node.cellId, node.cellName); })
        if (node.cellId !== this.currentTopCellId) {
          MenuItem({ content: `放置实例 / 阵列到 ${this.activeCellDisplayName()}…`, symbolStartIcon: menuIcon('pcell') })
            .attributeModifier(MENU_ITEM_STYLE)
            .onClick(() => { this.placeCellInstanceAction(node.cellId); })
        }
        MenuItem({ content: '新建子 Cell…', symbolStartIcon: menuIcon('new') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.newCellAction(); })
      }
      MenuItemGroup() {
        MenuItem({ content: '重命名 Cell…', symbolStartIcon: menuIcon('rename') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.renameCellAction(node.cellId); })
        MenuItem({ content: '展开全部实例…', symbolStartIcon: menuIcon('flatten') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.flattenCellAction(node.cellId); })
        MenuItem({ content: '单元维护与清理…', symbolStartIcon: menuIcon('settings') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.cellMaintenanceAction(); })
      }
      MenuItemGroup() {
        MenuItem({ content: '删除 Cell', symbolStartIcon: menuIcon('delete', true) })
          .attributeModifier(MENU_DANGER_ITEM_STYLE)
          .onClick(() => { this.deleteCellAction(node.cellId); })
      }
    }
  }

  private countCells(): number {
    if (this.cellDefinitionCount >= 0) return this.cellDefinitionCount;
    const definitions: Set<number> = new Set<number>();
    const stack: CellTreeNode[] = this.cellTree.slice();
    while (stack.length > 0) {
      const node = stack.pop();
      if (node) {
        definitions.add(node.cellId);
        for (let i = 0; i < node.children.length; i++) {
          stack.push(node.children[i]);
        }
      }
    }
    return definitions.size;
  }
}

@Component
struct LayerToolboxRow {
  @StorageProp('hongtuReduceMotion') reduceMotion: boolean = false;
  @Prop layer: UiLayer = {
    layerNumber: 0, datatype: 0, chineseName: '', englishName: '',
    color: '#FFFFFF', visible: false, elementCount: 0, group: LayerGroup.OTHER
  };
  @Prop elementCount: number = 0;
  @Prop isActive: boolean = false;
  toggleAction: (layerNumber: number, datatype: number) => void = () => {};
  selectAction: (layer: UiLayer) => void = () => {};
  styleLayerAction: (layer: UiLayer) => void = () => {};
  lockAction: (layerNumber: number, datatype: number) => void = () => {};
  selectableAction: (layerNumber: number, datatype: number, selectable: boolean) => void = () => {};
  selectAllOnLayerAction: (layerNumber: number, datatype: number) => void = () => {};
  clearLayerAction: (layerNumber: number, datatype: number) => void = () => {};
  deleteLayerAction: (layerNumber: number, datatype: number) => void = () => {};

  private displayName(): string {
    if (this.layer.chineseName.trim().length > 0 && this.layer.englishName.trim().length > 0 &&
      this.layer.chineseName !== this.layer.englishName) {
      return `${this.layer.englishName} ${this.layer.chineseName}`;
    }
    return this.layer.chineseName.trim().length > 0 ? this.layer.chineseName : this.layer.englishName;
  }

  build() {
    Row({ space: 3 }) {
      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({ name: this.layer.visible ? 'eye' : 'eyeOff', iconSize: 15,
          color: this.layer.visible ? COLORS.primary : COLORS.muted })
      }
      .width(24)
      .height(26)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(4)
      .focusable(false)
      .hitTestBehavior(HitTestMode.Block)
      .accessibilityText(this.layer.visible ? '隐藏图层' : '显示图层')
      .onClick(() => {
        this.toggleAction(this.layer.layerNumber, this.layer.datatype);
      })

      Button({ type: ButtonType.Normal }) {
        Row()
          .width(12)
          .height(12)
          .borderRadius(3)
          .backgroundColor(this.layer.color)
          .border({ width: 0.8, color: COLORS.border })
          .opacity(this.layer.visible ? 1.0 : 0.32)
      }
      .width(18).height(22).padding(0)
      .backgroundColor(Color.Transparent).borderRadius(4)
      .focusable(false)
      .hitTestBehavior(HitTestMode.Block)
      .bindTips('点击设置图层颜色与填充样式')
      .onClick(() => {
        this.selectAction(this.layer);
        this.styleLayerAction(this.layer);
      })

      Text(`${this.layer.layerNumber}/${this.layer.datatype}`)
        .fontSize(10.5)
        .fontColor(this.isActive ? COLORS.primary : COLORS.muted)
        .fontFamily(FONT_MONO)
        .constraintSize({ minWidth: 32, maxWidth: 46 })
        .maxLines(1)

      Text(this.displayName())
        .fontSize(11.5)
        .fontWeight(this.isActive ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.isActive ? COLORS.primary : (this.layer.visible ? COLORS.ink : COLORS.muted))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.elementCount > 0) {
        Text(this.elementCount > 9999 ? '9k+' : String(this.elementCount))
          .fontSize(9.5)
          .fontFamily(FONT_MONO)
          .fontColor(this.isActive ? COLORS.primary : COLORS.muted)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .backgroundColor(COLORS.surfaceMuted)
          .borderRadius(4)
      }

      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({ name: this.layer.locked === true ? 'lock' : 'menu', iconSize: 12,
          color: this.layer.locked === true ? COLORS.warning : COLORS.muted })
      }
      .width(20)
      .height(26)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(4)
      .focusable(false)
      .hitTestBehavior(HitTestMode.Block)
      .bindMenu(this.buildLayerContextMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
    }
    .width('100%')
    .height(30)
    .padding({ left: 2, right: 2 })
    .borderRadius(5)
    .animation(null)
    .backgroundColor(this.isActive ? COLORS.primarySoft : Color.Transparent)
    .animation({ duration: this.reduceMotion ? 0 : MOTION.feedback, curve: feedbackCurve() })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.selectAction(this.layer);
    })
    .bindContextMenu(this.buildLayerContextMenu, ResponseType.RightClick,
      buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
    .bindContextMenu(this.buildLayerContextMenu, ResponseType.LongPress,
      buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
  }

  @Builder
  buildLayerContextMenu() {
    Menu() {
      MenuItemGroup() {
        MenuItem({ content: '图层颜色与填充样式…', symbolStartIcon: menuIcon('style') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.styleLayerAction(this.layer); })
      }
      MenuItemGroup() {
        MenuItem({ content: '显示图层', symbolStartIcon: menuIcon('eye'),
          symbolEndIcon: menuCheckIcon(this.layer.visible) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.layer.visible)
          .onClick(() => { this.toggleAction(this.layer.layerNumber, this.layer.datatype); })
        MenuItem({ content: '锁定图层', symbolStartIcon: menuIcon('lock'),
          symbolEndIcon: menuCheckIcon(this.layer.locked === true) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.layer.locked === true)
          .onClick(() => { this.lockAction(this.layer.layerNumber, this.layer.datatype); })
        MenuItem({ content: '允许选择图层', symbolStartIcon: menuIcon('select'),
          symbolEndIcon: menuCheckIcon(this.layer.selectable !== false) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.layer.selectable !== false)
          .onClick(() => { this.selectableAction(this.layer.layerNumber, this.layer.datatype, this.layer.selectable === false); })
      }
      MenuItemGroup() {
        MenuItem({ content: '设为当前绘制层', symbolStartIcon: menuIcon('layer'),
          symbolEndIcon: menuCheckIcon(this.isActive) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.isActive)
          .onClick(() => { this.selectAction(this.layer); })
        MenuItem({ content: '选中本层全部图形', symbolStartIcon: menuIcon('selectAll') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.selectAllOnLayerAction(this.layer.layerNumber, this.layer.datatype); })
      }
      MenuItemGroup() {
        MenuItem({ content: '清空本层图形', symbolStartIcon: menuIcon('selectNone') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.clearLayerAction(this.layer.layerNumber, this.layer.datatype); })
        MenuItem({ content: '删除该图层（可撤销）', symbolStartIcon: menuIcon('delete', true) })
          .attributeModifier(MENU_DANGER_ITEM_STYLE)
          .onClick(() => { this.deleteLayerAction(this.layer.layerNumber, this.layer.datatype); })
      }
    }
    .attributeModifier(menuStyle([
      { content: '图层颜色与填充样式…', symbolStartIcon: menuIcon('style') },
      { content: '显示图层', symbolStartIcon: menuIcon('eye'), symbolEndIcon: menuCheckIcon(this.layer.visible) },
      { content: '锁定图层', symbolStartIcon: menuIcon('lock'), symbolEndIcon: menuCheckIcon(this.layer.locked === true) },
      { content: '允许选择图层', symbolStartIcon: menuIcon('select'), symbolEndIcon: menuCheckIcon(this.layer.selectable !== false) },
      { content: '设为当前绘制层', symbolStartIcon: menuIcon('layer'), symbolEndIcon: menuCheckIcon(this.isActive) },
      { content: '选中本层全部图形', symbolStartIcon: menuIcon('selectAll') },
      { content: '清空本层图形', symbolStartIcon: menuIcon('selectNone') },
      { content: '删除该图层（可撤销）', symbolStartIcon: menuIcon('delete', true) }
    ], this.getUIContext()))
  }
}
