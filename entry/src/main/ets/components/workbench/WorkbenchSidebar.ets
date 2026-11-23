import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { UiLayer, LayerGroup } from '../../common/types';
import { COLORS } from '../../common/constants';
import { RADIUS } from '../../common/MaterialTokens';
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
 * 鸿图高密度 KLayout 风格侧边栏（v7 上下双栏同屏：上 Cell 单元库层级 · 下 Layer 工艺图层）
 *
 * 1. 默认「同屏分栏」同时展示 Cell 单元树与工艺图层列表，彻底厘清「单元模块 (Cell)」与「工艺掩膜层 (Layer)」正交关系；
 * 2. 砍除冗余大留白、空视图预设行与重复表头，将图层行高精炼至 30vp，始终直显层号与当前 Cell 图形计数；
 * 3. Cell 区直显当前正在编辑的 Cell 身份（顶层主单元 vs 子单元）、一键返回顶层、新建子 Cell 及一键将子 Cell 实例化/阵列到当前版图；
 * 4. 图层区内置 KLayout 高频操作：全显、全隐、仅显示非空层过滤、预设与 .lyp 导入导出统一菜单。
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

/** 0=上下同屏分栏 (KLayout 默认), 1=仅工艺图层, 2=仅 Cell 单元 */
enum SidebarLayoutMode {
  Split = 0,
  LayersOnly = 1,
  CellsOnly = 2,
}

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
  private searchDebounceTimer: number = -1;

  private layerDataSource: ArrayDataSource<UiLayer> = new ArrayDataSource<UiLayer>();

  toggleLayerAction: (layerNumber: number, visible: boolean, datatype: number) => void = () => {};
  selectLayerAction: (layer: UiLayer) => void = () => {};
  styleLayerAction: (layer: UiLayer) => void = () => {};
  openShortcutAction: () => void = () => {};
  setTopCellAction: (cellId: number, cellName: string) => void = () => {};
  newCellAction: () => void = () => {};
  placeCellInstanceAction: (cellId: number) => void = (_cellId: number) => {};
  deleteCellAction: (cellId: number) => void = () => {};
  renameCellAction: (cellId: number) => void = () => {};
  flattenCellAction: (cellId: number) => void = () => {};
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

  private buildLayoutModeItems(): SegmentButtonItemTuple {
    const items: [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] = [
      { text: '分栏' },
      { text: '图层' },
      { text: 'Cell' }
    ];
    return items;
  }

  private activeCellDisplayName(): string {
    if (this.currentEditingCellName.length > 0) return this.currentEditingCellName;
    const stack: CellTreeNode[] = [...this.cellTree];
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
      .fontSize(10.5)
      .padding({ left: 6, right: 6 })
      .fontColor(active ? COLORS.primary : COLORS.muted)
      .backgroundColor(active ? COLORS.primarySoft : Color.Transparent)
      .border({ width: active ? 0.8 : 0, color: active ? COLORS.primary : Color.Transparent })
      .borderRadius(5)
      .focusable(false)
      .onClick(() => onTap())
  }

  build() {
    Column({ space: 4 }) {
      // 紧凑顶栏：面板切换（分栏 / 仅图层 / 仅Cell）+ 搜索与更多菜单（仅占 30vp）
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
            fontSizeFp: 11,
            capsuleBorderRadius: 6,
            buttonMinHeight: 26,
            itemMinHeight: 22,
            itemPaddingHorizontal: 6,
            itemPaddingVertical: 2
          })
        }.layoutWeight(1)

        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({ name: 'search', iconSize: 14, color: (this.showSearchInput || this.searchKey.length > 0) ? COLORS.primary : COLORS.muted })
        }
        .width(26).height(26).padding(0)
        .backgroundColor((this.showSearchInput || this.searchKey.length > 0) ? COLORS.primarySoft : COLORS.surfaceMuted)
        .borderRadius(6).focusable(false)
        .accessibilityText('搜索过滤图层')
        .bindTips('搜索图层名称或层号')
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
        .accessibilityText('图层预设与 LYP 菜单')
        .bindTips('导入/导出 .lyp 图层属性与视图预设')
        .bindMenu(this.buildLypAndPresetMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
      }
      .width('100%')
      .height(30)
      .margin({ top: 4 })
      .alignItems(VerticalAlign.Center)

      // ===== 上半栏：Cell 单元库与层级结构（对齐 KLayout Cells 面板） =====
      if (this.layoutMode !== SidebarLayoutMode.LayersOnly) {
        this.buildCellsPane()
      }

      // 分隔细线
      if (this.layoutMode === SidebarLayoutMode.Split) {
        Row().width('100%').height(0.8).backgroundColor(COLORS.border)
      }

      // ===== 下半栏：工艺掩膜图层（对齐 KLayout Layers 面板） =====
      if (this.layoutMode !== SidebarLayoutMode.CellsOnly) {
        this.buildLayersPane()
      }

      if (this.showShortcutFooter) {
        Button({ type: ButtonType.Normal }) {
          Row() {
            WorkbenchIcon({ name: 'info', iconSize: 14, color: COLORS.primary })
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
      MenuItemGroup({ header: '图层显示快捷控制' }) {
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
  private buildCellsPane() {
    Column({ space: 3 }) {
      // Cell 栏标题行（26vp）：支持一键折叠、+新建子Cell、放实例/阵列
      Row({ space: 4 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 3 }) {
            WorkbenchIcon({
              name: this.cellsCollapsed && this.layoutMode === SidebarLayoutMode.Split ? 'chevronRight' : 'chevronDown',
              iconSize: 12,
              color: COLORS.muted
            })
            Text(`单元 Cells (${this.countCells()})`)
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
          .height(22).fontSize(10.5).padding({ left: 6, right: 6 })
          .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft)
          .borderRadius(5).focusable(false)
          .bindTips('新建子单元 Cell 并进入绘制单元结构')
          .onClick(() => this.newCellAction())

        Button('放实例/阵列', { type: ButtonType.Normal })
          .height(22).fontSize(10.5).padding({ left: 6, right: 6 })
          .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
          .border({ width: 0.8, color: COLORS.border }).borderRadius(5).focusable(false)
          .bindTips('在当前 Cell 中引用其他子 Cell（支持单放与 Rows×Cols 行列阵列）')
          .onClick(() => this.placeCellInstanceAction(-1))
      }
      .width('100%')
      .height(26)
      .alignItems(VerticalAlign.Center)

      // 当前正在编辑的 Cell 醒目提示条（彻底解决在哪个 Cell 画图的混淆）
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
        if (this.cellTree.length === 0) {
          Text('暂无 Cell 定义')
            .fontSize(11)
            .fontColor(COLORS.muted)
            .padding({ top: 8, bottom: 8, left: 6 })
        } else {
          List() {
            ForEach(this.cellTree, (node: CellTreeNode) => {
              this.buildCellNodeRow(node)
            }, (node: CellTreeNode) => this.cellRowKey(node))
          }
          .width('100%')
          .layoutWeight(this.layoutMode === SidebarLayoutMode.CellsOnly ? 1 : 0)
          .constraintSize({
            minHeight: this.layoutMode === SidebarLayoutMode.CellsOnly ? 0 : 60,
            maxHeight: this.layoutMode === SidebarLayoutMode.CellsOnly ? 2000 : 148
          })
          .cachedCount(10)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .clip(true)
        }
      }
    }
    .width('100%')
    .layoutWeight(this.layoutMode === SidebarLayoutMode.CellsOnly ? 1 : 0)
  }

  @Builder
  private buildLayersPane() {
    Column({ space: 3 }) {
      // 图层栏紧凑标题与一键过滤行（26vp）
      Row({ space: 3 }) {
        Text(`工艺层 (${this.visibleLayerCount()}/${this.layers.length})`)
          .fontSize(11.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
          .maxLines(1)
        this.tinyHeaderTextBtn('全显', false, () => this.setAllLayersVisibility(true))
        this.tinyHeaderTextBtn('全隐', false, () => this.setAllLayersVisibility(false))
        this.tinyHeaderTextBtn('非空', this.nonEmptyOnly, () => { this.nonEmptyOnly = !this.nonEmptyOnly; })
      }
      .width('100%')
      .height(26)
      .alignItems(VerticalAlign.Center)

      if (this.showSearchInput) {
        Search({ value: this.searchKey, placeholder: '搜层名或 1/0…' })
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
          .margin({ top: 0, bottom: 2 })
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
            }, 120);
          })
      }

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
              }
            })
          }
        }, (layer: UiLayer) => this.layerRowKey(layer))
      }
      .layoutWeight(1)
      .width('100%')
      .cachedCount(16)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)
    }
    .layoutWeight(1)
    .width('100%')
  }

  private cellRowKey(node: CellTreeNode): string {
    return `${node.key()}:${node.cellName}:${node.referenceCount}:${node.expanded}:${node.children.length}:${this.currentTopCellId}:${this.rootTopCellId}`;
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

    if (node.expanded && node.children.length > 0) {
      ForEach(node.children, (child: CellTreeNode) => {
        this.buildCellNodeRow(child)
      }, (child: CellTreeNode) => this.cellRowKey(child))
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
    const stack: CellTreeNode[] = [...this.cellTree];
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
    }
    .attributeModifier(menuStyle([
      { content: '图层颜色与填充样式…', symbolStartIcon: menuIcon('style') },
      { content: '显示图层', symbolStartIcon: menuIcon('eye'), symbolEndIcon: menuCheckIcon(this.layer.visible) },
      { content: '锁定图层', symbolStartIcon: menuIcon('lock'), symbolEndIcon: menuCheckIcon(this.layer.locked === true) },
      { content: '允许选择图层', symbolStartIcon: menuIcon('select'), symbolEndIcon: menuCheckIcon(this.layer.selectable !== false) },
      { content: '设为当前绘制层', symbolStartIcon: menuIcon('layer'), symbolEndIcon: menuCheckIcon(this.isActive) },
      { content: '选中本层全部图形', symbolStartIcon: menuIcon('selectAll') }
    ], this.getUIContext()))
  }
}
