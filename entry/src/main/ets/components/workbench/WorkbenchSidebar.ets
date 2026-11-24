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

/**
 * 鸿图左侧专业版图双层侧边栏（对齐参考布局：顶部下划线标签页 + 单元库树 + 五列结构化图层表）
 *
 * 1. 顶部清晰下划线标签栏：`单元`（默认上下可拖拽双栏同显单元库与图层） | `图层` | `层级` | `快放`；
 * 2. 上栏「单元库 (N)」：蓝色实心 `+ 新建` + `导入 ▾` 下拉 + 常驻通配符搜索框（原生支持 `*` / `?` 通配符）+ 筛选按钮；
 * 3. 下栏「图层 (可见/总数)」：蓝色实心 `+ 新建` + `⋯` 菜单（保留全部 LYP/预设测试 ID）+ 五列表头（可见 | 锁定 | 颜色 | 图层名 | 图形数），
 *    锁定列支持单次点击直接加解锁，右键/长按弹出完整图层生命周期菜单。
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

/** 0=单元+图层上下双栏(参考图默认), 1=仅图层全高, 2=层级全高, 3=快放与预设 */
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

function matchesWildcardQuery(candidate: string, rawQuery: string): boolean {
  const q: string = rawQuery.trim().toLowerCase();
  if (q.length === 0) return true;
  const target: string = candidate.toLowerCase();
  if (q.indexOf('*') < 0 && q.indexOf('?') < 0) {
    return target.includes(q);
  }
  let pattern: string = '';
  for (let i = 0; i < q.length; i++) {
    const ch: string = q[i];
    if (ch === '*') {
      pattern += '.*';
    } else if (ch === '?') {
      pattern += '.';
    } else if ('\\^$.|+()[]{}'.indexOf(ch) >= 0) {
      pattern += '\\' + ch;
    } else {
      pattern += ch;
    }
  }
  try {
    return new RegExp(pattern).test(target);
  } catch (_) {
    return target.includes(q);
  }
}

@Component
export struct WorkbenchSidebar {
  @Prop @Watch('onLayerDataChanged') layers: UiLayer[] = [];
  @Prop @Watch('onLayerDataChanged') selectedLayerNumber: number = -1;
  @Prop @Watch('onLayerDataChanged') selectedDatatype: number = 0;
  @Prop sidebarWidth: number = UI.sidebarWidth;
  @Prop visible: boolean = true;
  @Prop showShortcutFooter: boolean = true;
  @Prop hierarchyDepth: number = 2;
  @Prop @Watch('onPresetNamesChanged') presetNames: string[] = [];
  @State selectedPresetName: string = '';

  @Prop cellTree: CellTreeNode[] = [];
  @Prop cellDefinitionCount: number = -1;
  @Prop currentTopCellId: number = 0;
  @Prop rootTopCellId: number = 0;
  @Prop currentEditingCellName: string = 'TOP';

  @State @Watch('onLayerDataChanged') searchKey: string = '';
  @State @Watch('onLayerDataChanged') nonEmptyOnly: boolean = false;
  @State private referencedCellsOnly: boolean = false;
  @State private layoutMode: SidebarLayoutMode = SidebarLayoutMode.Split;
  @State private cellsSplitWeight: number = 50;
  private dragStartWeight: number = 50;
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
  importMergeAction: () => void = () => {};
  placeCellInstanceAction: (cellId: number) => void = (_cellId: number) => {};
  deleteCellAction: (cellId: number) => void = () => {};
  renameCellAction: (cellId: number) => void = () => {};
  flattenCellAction: (cellId: number) => void = () => {};
  cellMaintenanceAction: () => void = () => {};
  openPCellAction: () => void = () => {};
  openCurveAction: (kind: string) => void = (_k: string) => {};
  makeCellFromSelectionAction: () => void = () => {};
  arrayCopySelectionAction: () => void = () => {};
  setHierarchyDepthAction: (depth: number) => void = (_d: number) => {};
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
    const key: string = this.searchKey.trim();
    const result: UiLayer[] = [];
    for (let i = 0; i < this.layers.length; i++) {
      const layer: UiLayer = this.layers[i];
      const isSelected: boolean = layer.layerNumber === this.selectedLayerNumber && layer.datatype === this.selectedDatatype;
      if (this.nonEmptyOnly && layer.elementCount <= 0 && !isSelected) {
        continue;
      }
      if (this.layoutMode === SidebarLayoutMode.Split) {
        // 分栏态下顶部搜索框专注筛选单元库（如参考图“搜索单元”），在「图层」专页下同步过滤图层
        result.push(layer);
        continue;
      }
      if (key.length === 0 ||
        matchesWildcardQuery(layer.chineseName, key) ||
        matchesWildcardQuery(layer.englishName, key) ||
        matchesWildcardQuery(`${layer.layerNumber}/${layer.datatype}`, key) ||
        matchesWildcardQuery(`L${layer.layerNumber}`, key)) {
        result.push(layer);
      }
    }
    return result;
  }

  private nodeMatchesSearch(node: CellTreeNode, key: string): boolean {
    if (this.referencedCellsOnly && node.depth > 0 && node.referenceCount <= 0 && node.children.length === 0) {
      return false;
    }
    if (key.length === 0) return true;
    if (matchesWildcardQuery(node.cellName, key)) return true;
    for (let i = 0; i < node.children.length; i++) {
      if (this.nodeMatchesSearch(node.children[i], key)) return true;
    }
    return false;
  }

  private filteredCellRoots(): CellTreeNode[] {
    const key: string = this.searchKey.trim();
    if (key.length === 0 && !this.referencedCellsOnly) return this.cellTree;
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
  private buildTopTabButton(mode: SidebarLayoutMode, title: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 0 }) {
        Text(title)
          .fontSize(12.5)
          .fontWeight(this.layoutMode === mode ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.layoutMode === mode ? COLORS.primary : COLORS.muted)
          .layoutWeight(1)
        Row()
          .width(24)
          .height(2)
          .borderRadius(1)
          .backgroundColor(this.layoutMode === mode ? COLORS.primary : Color.Transparent)
      }
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .layoutWeight(1)
    .height(36)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .borderRadius(0)
    .focusable(false)
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      this.layoutMode = mode;
      this.onLayerDataChanged();
    })
  }

  @Builder
  private buildSplitHandle() {
    Column() {
      Row()
        .width('100%')
        .height(0.8)
        .backgroundColor(COLORS.border)
      Row()
        .width(28)
        .height(2.5)
        .borderRadius(2)
        .backgroundColor(COLORS.border)
        .margin({ top: 3 })
    }
    .width('100%')
    .height(10)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .bindTips('上下拖动调整单元库与图层高度比例（双击复位）')
    .gesture(
      PanGesture({ direction: PanDirection.Vertical, distance: 2 })
        .onActionStart(() => {
          this.dragStartWeight = this.cellsSplitWeight;
        })
        .onActionUpdate((event: GestureEvent) => {
          const totalH: number = Math.max(240, this.sidebarBodyHeightVp);
          const deltaPct: number = Math.round((event.offsetY / totalH) * 100);
          this.cellsSplitWeight = Math.min(72, Math.max(24, this.dragStartWeight + deltaPct));
        })
    )
    .gesture(
      TapGesture({ count: 2 })
        .onAction(() => {
          this.cellsSplitWeight = 50;
        })
    )
  }

  @Builder
  private buildCellImportMenu() {
    Menu() {
      MenuItemGroup({ header: '单元导入与组装' }) {
        MenuItem({ content: '导入合并外部版图 (GDS/OAS)…', symbolStartIcon: menuIcon('import') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.importMergeAction())
        MenuItem({ content: '放置子单元实例 / 阵列…', symbolStartIcon: menuIcon('instance') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.placeCellInstanceAction(-1))
        MenuItem({ content: '将当前选区封装为新单元…', symbolStartIcon: menuIcon('cell') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.makeCellFromSelectionAction())
      }
      MenuItemGroup({ header: '单元库维护' }) {
        MenuItem({ content: '引用统计与孤立单元清理…', symbolStartIcon: menuIcon('settings') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.cellMaintenanceAction())
      }
    }
    .attributeModifier(menuStyle([
      { content: '导入合并外部版图 (GDS/OAS)…', symbolStartIcon: menuIcon('import') },
      { content: '放置子单元实例 / 阵列…', symbolStartIcon: menuIcon('instance') },
      { content: '将当前选区封装为新单元…', symbolStartIcon: menuIcon('cell') },
      { content: '引用统计与孤立单元清理…', symbolStartIcon: menuIcon('settings') }
    ], this.getUIContext()))
  }

  @Builder
  private buildCellFilterMenu() {
    Menu() {
      MenuItemGroup({ header: '列表筛选' }) {
        MenuItem({ content: '仅显示已被引用的子单元', symbolStartIcon: menuIcon('cell'),
          symbolEndIcon: menuCheckIcon(this.referencedCellsOnly) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.referencedCellsOnly)
          .onClick(() => { this.referencedCellsOnly = !this.referencedCellsOnly; })
        MenuItem({ content: '仅显示非空图层', symbolStartIcon: menuIcon('layer'),
          symbolEndIcon: menuCheckIcon(this.nonEmptyOnly) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.nonEmptyOnly)
          .onClick(() => { this.nonEmptyOnly = !this.nonEmptyOnly; })
        MenuItem({ content: '重置全部筛选条件', symbolStartIcon: menuIcon('reset') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => {
            this.referencedCellsOnly = false;
            this.nonEmptyOnly = false;
            this.searchKey = '';
            AppStorage.setOrCreate<string>('layerSearchKey', '');
            this.onLayerDataChanged();
          })
      }
    }
    .attributeModifier(menuStyle([
      { content: '仅显示已被引用的子单元', symbolStartIcon: menuIcon('cell'), symbolEndIcon: menuCheckIcon(this.referencedCellsOnly) },
      { content: '仅显示非空图层', symbolStartIcon: menuIcon('layer'), symbolEndIcon: menuCheckIcon(this.nonEmptyOnly) },
      { content: '重置全部筛选条件', symbolStartIcon: menuIcon('reset') }
    ], this.getUIContext()))
  }

  build() {
    Column({ space: 0 }) {
      // 1. 顶部下划线标签栏（单元 | 图层 | 层级 | 快放）
      Row({ space: 0 }) {
        this.buildTopTabButton(SidebarLayoutMode.Split, '单元')
        this.buildTopTabButton(SidebarLayoutMode.LayersOnly, '图层')
        this.buildTopTabButton(SidebarLayoutMode.CellsOnly, '层级')
        this.buildTopTabButton(SidebarLayoutMode.QuickStamp, '快放')
      }
      .width('100%')
      .height(36)
      .padding({ left: 4, right: 4 })
      .border({ width: { bottom: 0.8 }, color: COLORS.border })

      // 2. 主体双层/单层内容容器
      Column({ space: 4 }) {
        if (this.layoutMode === SidebarLayoutMode.QuickStamp) {
          this.buildQuickStampPane()
        } else {
          if (this.layoutMode !== SidebarLayoutMode.LayersOnly) {
            this.buildCellsPane()
          }

          if (this.layoutMode === SidebarLayoutMode.Split) {
            this.buildSplitHandle()
          }

          if (this.layoutMode !== SidebarLayoutMode.CellsOnly) {
            this.buildLayersPane()
          }
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 6 })
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
        .width('92%')
        .height(30)
        .margin({ bottom: 6 })
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
    .alignItems(HorizontalAlign.Center)
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
        Column({ space: 6 }) {
          Row() {
            Text('光子/版图几何快放')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
            Button('PCell 库', { type: ButtonType.Normal })
              .height(24).fontSize(10.5).padding({ left: 8, right: 8 })
              .fontColor('#FFFFFF').backgroundColor(COLORS.primary).borderRadius(6).focusable(false)
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

        Column({ space: 5 }) {
          Row() {
            Text(`可引用子单元 (${this.collectPlaceableSubCells().length})`)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
            Button('+ 新建', { type: ButtonType.Normal })
              .height(24).fontSize(10.5).padding({ left: 8, right: 8 })
              .fontColor('#FFFFFF').backgroundColor(COLORS.primary).borderRadius(6).focusable(false)
              .onClick(() => this.newCellAction())
          }.width('100%').alignItems(VerticalAlign.Center)

          if (this.collectPlaceableSubCells().length === 0) {
            Text('当前库暂无可引用的其他子单元，点击右上角「+ 新建」创建子单元后即可一键引用或排阵列。')
              .fontSize(10.5)
              .lineHeight(16)
              .fontColor(COLORS.muted)
              .padding(8)
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
                Button('引用', { type: ButtonType.Normal })
                  .height(22).fontSize(10).padding({ left: 7, right: 7 })
                  .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft)
                  .borderRadius(5).focusable(false)
                  .onClick(() => this.placeCellInstanceAction(sub.cellId))
              }
              .width('100%')
              .height(30)
              .padding({ left: 6, right: 6 })
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(6)
              .alignItems(VerticalAlign.Center)
            }, (sub: CellTreeNode): string => `qsub_${sub.cellId}_${sub.cellName}`)
          }
        }.width('100%').alignItems(HorizontalAlign.Start)

        Divider().color(COLORS.border)

        Column({ space: 5 }) {
          Row() {
            Text('视图预设与 LYP')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
            Button('保存预设', { type: ButtonType.Normal })
              .height(24).fontSize(10.5).padding({ left: 8, right: 8 })
              .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border }).borderRadius(6).focusable(false)
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
            .borderRadius(6)
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
              .border({ width: 0.8, color: COLORS.border }).borderRadius(6).focusable(false)
              .onClick(() => this.importLypAction())
            Button('导出 .lyp', { type: ButtonType.Normal })
              .height(26).fontSize(10.5).layoutWeight(1)
              .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 0.8, color: COLORS.border }).borderRadius(6).focusable(false)
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
    Column({ space: 6 }) {
      // 1. 单元库标题行（对齐参考图：单元库 (N) + 蓝色实心「+ 新建」+「导入 ▾」）
      Row({ space: 6 }) {
        Text(`单元库 (${this.countCells()})`)
          .fontSize(12.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
          .maxLines(1)

        if (this.isEditingSubCell()) {
          Button('回顶层', { type: ButtonType.Normal })
            .height(24)
            .fontSize(10.5)
            .padding({ left: 7, right: 7 })
            .fontColor(COLORS.primary)
            .backgroundColor(COLORS.primarySoft)
            .border({ width: 0.8, color: COLORS.primary })
            .borderRadius(6)
            .focusable(false)
            .onClick(() => this.setTopCellAction(this.rootTopCellId, this.rootTopCellName()))
        }

        Button('+ 新建', { type: ButtonType.Normal })
          .height(26)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .padding({ left: 9, right: 9 })
          .fontColor('#FFFFFF')
          .backgroundColor(COLORS.primary)
          .borderRadius(6)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .focusable(false)
          .bindTips('新建子单元 Cell 并切入绘图')
          .onClick(() => this.newCellAction())

        Button({ type: ButtonType.Normal }) {
          Row({ space: 3 }) {
            Text('导入')
              .fontSize(11)
              .fontColor(COLORS.ink)
            WorkbenchIcon({ name: 'chevronDown', iconSize: 10, color: COLORS.muted })
          }.alignItems(VerticalAlign.Center)
        }
        .height(26)
        .padding({ left: 8, right: 7 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 0.8, color: COLORS.border })
        .borderRadius(6)
        .focusable(false)
        .bindTips('导入合并版图、放置实例或维护单元库')
        .bindMenu(this.buildCellImportMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
      }
      .width('100%')
      .height(28)
      .alignItems(VerticalAlign.Center)

      // 2. 常驻搜索框（支持通配符 * ?）+ 漏斗筛选按钮
      Row({ space: 6 }) {
        Search({ value: this.searchKey, placeholder: '搜索单元 (支持通配符 * ?)' })
          .layoutWeight(1)
          .height(30)
          .textFont({ size: 11.5 })
          .placeholderFont({ size: 11 })
          .fontColor(COLORS.ink)
          .placeholderColor(COLORS.muted)
          .searchIcon({ size: 13, color: COLORS.muted })
          .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 12, color: COLORS.muted } })
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 0.8, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .margin(0)
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
            }, 90);
          })

        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({
            name: 'filter',
            iconSize: 14,
            color: (this.referencedCellsOnly || this.nonEmptyOnly) ? COLORS.primary : COLORS.muted
          })
        }
        .width(30)
        .height(30)
        .padding(0)
        .backgroundColor((this.referencedCellsOnly || this.nonEmptyOnly) ? COLORS.primarySoft : COLORS.surfaceMuted)
        .border({
          width: 0.8,
          color: (this.referencedCellsOnly || this.nonEmptyOnly) ? COLORS.primary : COLORS.border
        })
        .borderRadius(UI.controlRadius)
        .focusable(false)
        .accessibilityText('筛选单元与图层列表')
        .bindTips('按引用状态或非空状态筛选')
        .bindMenu(this.buildCellFilterMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 层级专页附加展开深度快捷栏
      if (this.layoutMode === SidebarLayoutMode.CellsOnly) {
        Row({ space: 4 }) {
          Text('展开深度:')
            .fontSize(10.5)
            .fontColor(COLORS.muted)
          ForEach([1, 2, 4, 32], (d: number) => {
            Button(d === 32 ? '全部' : `${d}层`, { type: ButtonType.Normal })
              .height(22)
              .fontSize(10)
              .padding({ left: 7, right: 7 })
              .fontColor(this.hierarchyDepth === d ? COLORS.primary : COLORS.muted)
              .backgroundColor(this.hierarchyDepth === d ? COLORS.primarySoft : COLORS.surfaceMuted)
              .border({ width: 0.8, color: this.hierarchyDepth === d ? COLORS.primary : COLORS.border })
              .borderRadius(5)
              .focusable(false)
              .onClick(() => this.setHierarchyDepthAction(d))
          }, (d: number): string => `hd_${d}_${this.hierarchyDepth}`)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // 3. 单元树列表
      if (this.filteredCellRoots().length === 0) {
        Text(this.searchKey.trim().length > 0 ? '无匹配单元' : '暂无单元定义')
          .fontSize(11.5)
          .fontColor(COLORS.muted)
          .padding({ top: 10, bottom: 10, left: 4 })
      } else {
        List({ space: 2 }) {
          ForEach(this.filteredCellRoots(), (node: CellTreeNode) => {
            this.buildCellNodeRow(node)
          }, (node: CellTreeNode) => this.cellRowKey(node))
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(16)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(true)
      }
    }
    .width('100%')
    .layoutWeight(
      this.layoutMode === SidebarLayoutMode.CellsOnly
        ? 1
        : this.cellsSplitWeight
    )
  }

  @Builder
  private buildLayersPane() {
    Column({ space: 5 }) {
      // 1. 图层区标题行（对齐参考图：图层 (可见/总数) + 蓝色实心「+ 新建」+「⋯」菜单）
      Row({ space: 6 }) {
        Text(`图层 (${this.visibleLayerCount()}/${this.layers.length})`)
          .fontSize(12.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
          .maxLines(1)

        Button('+ 新建', { type: ButtonType.Normal })
          .height(25)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .padding({ left: 9, right: 9 })
          .fontColor('#FFFFFF')
          .backgroundColor(COLORS.primary)
          .borderRadius(6)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .focusable(false)
          .bindTips('新建一个可用工艺层并设为当前绘图层')
          .onClick(() => this.addLayerAction())

        Button({ type: ButtonType.Normal }) {
          Row({ space: 2.5 }) {
            Circle({ width: 3, height: 3 }).fill(COLORS.ink)
            Circle({ width: 3, height: 3 }).fill(COLORS.ink)
            Circle({ width: 3, height: 3 }).fill(COLORS.ink)
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
        }
        .id('layer-panel-menu')
        .width(26)
        .height(25)
        .padding(0)
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 0.8, color: COLORS.border })
        .borderRadius(6)
        .focusable(false)
        .accessibilityText('图层管理、预设与 LYP 菜单')
        .bindTips('全显/全隐、清理空层、导入导出 .lyp 与视图预设')
        .bindMenu(this.buildLypAndPresetMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
      }
      .width('100%')
      .height(28)
      .alignItems(VerticalAlign.Center)

      if (this.layoutMode === SidebarLayoutMode.LayersOnly) {
        Search({ value: this.searchKey, placeholder: '搜索图层名称或层号 (如 1/0)…' })
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
          .borderRadius(UI.controlRadius)
          .margin(0)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation())
          .onChange((value: string) => {
            this.searchKey = value;
            AppStorage.setOrCreate<string>('layerSearchKey', value);
            this.onLayerDataChanged();
          })
      }

      // 2. 五列结构化表头（可见 | 锁定 | 颜色 | 图层名 | 图形数）
      Row({ space: 2 }) {
        Text('可见')
          .fontSize(10.5)
          .fontColor(COLORS.muted)
          .width(28)
          .textAlign(TextAlign.Center)
        Text('锁定')
          .fontSize(10.5)
          .fontColor(COLORS.muted)
          .width(28)
          .textAlign(TextAlign.Center)
        Text('颜色')
          .fontSize(10.5)
          .fontColor(COLORS.muted)
          .width(28)
          .textAlign(TextAlign.Center)
        Text('图层名')
          .fontSize(10.5)
          .fontColor(COLORS.muted)
          .layoutWeight(1)
          .padding({ left: 4 })
        Text('图形数')
          .fontSize(10.5)
          .fontColor(COLORS.muted)
          .width(42)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .height(24)
      .padding({ left: 2, right: 4 })
      .backgroundColor(COLORS.surfaceMuted)
      .borderRadius(5)
      .alignItems(VerticalAlign.Center)

      // 3. 图层列表
      List({ space: 2 }) {
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
      this.layoutMode === SidebarLayoutMode.LayersOnly
        ? 1
        : Math.max(28, 100 - this.cellsSplitWeight)
    )
    .width('100%')
  }

  private cellRowKey(node: CellTreeNode): string {
    return `${node.key()}:${node.cellName}:${node.referenceCount}:${node.expanded}:${node.children.length}:${this.currentTopCellId}:${this.rootTopCellId}:${this.searchKey}:${this.referencedCellsOnly}`;
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
    return Math.min(depth * 14, Math.max(0, this.sidebarWidth - 156));
  }

  @Builder
  buildCellNodeRow(node: CellTreeNode) {
    ListItem() {
      Row({ space: 4 }) {
        if (node.depth > 0) {
          Row().width(this.cellRowIndent(node.depth))
        }

        if (node.children.length > 0) {
          Button({ type: ButtonType.Normal }) {
            WorkbenchIcon({
              name: node.expanded ? 'chevronDown' : 'chevronRight',
              iconSize: 11,
              color: node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.muted
            })
          }
          .width(18).height(24).padding(0).backgroundColor(Color.Transparent).borderRadius(4).focusable(false)
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onMouse((event: MouseEvent) => event.stopPropagation())
          .onClick(() => this.toggleCellExpanded(node.path))
        } else {
          Row().width(14)
        }

        WorkbenchIcon({
          name: node.depth === 0 ? 'open' : 'cell',
          iconSize: 14,
          color: node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.ink
        })

        Text(node.cellName)
          .fontSize(12)
          .fontColor(node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.ink)
          .fontWeight(node.cellId === this.currentTopCellId ? FontWeight.Bold : FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .bindTips(node.cellId === this.rootTopCellId ? `${node.cellName} (顶层主单元，双击切换)` : `${node.cellName} (双击进入编辑，点“引用”放置到当前单元)`)

        if (node.cellId !== this.currentTopCellId) {
          Button('引用', { type: ButtonType.Normal })
            .height(21)
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .padding({ left: 7, right: 7 })
            .fontColor(COLORS.primary)
            .backgroundColor(COLORS.primarySoft)
            .borderRadius(4)
            .focusable(false)
            .bindTips(`将 ${node.cellName} 作为实例或阵列放入 ${this.activeCellDisplayName()}`)
            .onTouch((event: TouchEvent) => event.stopPropagation())
            .onMouse((event: MouseEvent) => event.stopPropagation())
            .onClick(() => this.placeCellInstanceAction(node.cellId))
        }

        Text(node.depth === 0 ? `${Math.max(1, this.countCells())}` : `${node.referenceCount}`)
          .fontSize(11)
          .fontFamily(FONT_MONO)
          .fontColor(node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.muted)
          .constraintSize({ minWidth: 20 })
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .height(30)
      .padding({ left: 4, right: 6 })
      .borderRadius(6)
      .backgroundColor(node.cellId === this.currentTopCellId ? COLORS.primarySoft : Color.Transparent)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (node.depth === 0 && node.children.length > 0 && node.cellId === this.currentTopCellId) {
          this.toggleCellExpanded(node.path);
        }
      })
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
        node.children.filter((c: CellTreeNode): boolean => this.nodeMatchesSearch(c, this.searchKey.trim())),
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
        MenuItem({ content: '进入编辑该单元', symbolStartIcon: menuIcon('cell'),
          symbolEndIcon: menuCheckIcon(node.cellId === this.currentTopCellId) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(node.cellId === this.currentTopCellId)
          .onClick(() => { this.setTopCellAction(node.cellId, node.cellName); })
        if (node.cellId !== this.currentTopCellId) {
          MenuItem({ content: `放置实例 / 阵列到 ${this.activeCellDisplayName()}…`, symbolStartIcon: menuIcon('pcell') })
            .attributeModifier(MENU_ITEM_STYLE)
            .onClick(() => { this.placeCellInstanceAction(node.cellId); })
        }
        MenuItem({ content: '新建子单元…', symbolStartIcon: menuIcon('new') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.newCellAction(); })
      }
      MenuItemGroup() {
        MenuItem({ content: '重命名单元…', symbolStartIcon: menuIcon('rename') })
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
        MenuItem({ content: '删除单元', symbolStartIcon: menuIcon('delete', true) })
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

  private formattedLayerName(): string {
    const codeTag: string = this.layer.datatype !== 0
      ? `L${this.layer.layerNumber}/${this.layer.datatype}`
      : `L${this.layer.layerNumber}`;
    const cn: string = this.layer.chineseName.trim();
    const en: string = this.layer.englishName.trim();
    if (cn.length > 0 && cn !== codeTag) {
      return `${codeTag} ${cn}`;
    }
    if (en.length > 0 && en !== codeTag) {
      return `${codeTag} ${en}`;
    }
    return codeTag;
  }

  build() {
    Row({ space: 2 }) {
      // 第 1 列：可见
      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({
          name: this.layer.visible ? 'eye' : 'eyeOff',
          iconSize: 15,
          color: this.layer.visible ? COLORS.primary : COLORS.muted
        })
      }
      .width(28)
      .height(28)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(5)
      .focusable(false)
      .hitTestBehavior(HitTestMode.Block)
      .accessibilityText(this.layer.visible ? '隐藏图层' : '显示图层')
      .onClick(() => {
        this.toggleAction(this.layer.layerNumber, this.layer.datatype);
      })

      // 第 2 列：锁定（单击直接切换锁定状态）
      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({
          name: this.layer.locked === true ? 'lock' : 'unlock',
          iconSize: 14,
          color: this.layer.locked === true ? COLORS.warning : COLORS.muted
        })
      }
      .width(28)
      .height(28)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(5)
      .focusable(false)
      .hitTestBehavior(HitTestMode.Block)
      .accessibilityText(this.layer.locked === true ? '解锁图层' : '锁定图层')
      .bindTips(this.layer.locked === true ? '已锁定（点击解锁）' : '未锁定（点击锁定）')
      .onClick(() => {
        this.lockAction(this.layer.layerNumber, this.layer.datatype);
      })

      // 第 3 列：颜色圆角色块（点击打开图层颜色与填充样式面板）
      Button({ type: ButtonType.Normal }) {
        Row()
          .width(15)
          .height(15)
          .borderRadius(4)
          .backgroundColor(this.layer.color)
          .border({ width: 0.8, color: COLORS.border })
          .opacity(this.layer.visible ? 1.0 : 0.35)
      }
      .width(28)
      .height(28)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(5)
      .focusable(false)
      .hitTestBehavior(HitTestMode.Block)
      .bindTips('点击设置图层颜色、填充与透明度')
      .onClick(() => {
        this.selectAction(this.layer);
        this.styleLayerAction(this.layer);
      })

      // 第 4 列：图层名
      Text(this.formattedLayerName())
        .fontSize(12)
        .fontWeight(this.isActive ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.isActive ? COLORS.primary : (this.layer.visible ? COLORS.ink : COLORS.muted))
        .layoutWeight(1)
        .padding({ left: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 第 5 列：图形数
      Text(this.elementCount > 99999 ? '99k+' : String(this.elementCount))
        .fontSize(11)
        .fontFamily(FONT_MONO)
        .fontColor(this.isActive ? COLORS.primary : COLORS.muted)
        .width(42)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(32)
    .padding({ left: 2, right: 4 })
    .borderRadius(6)
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
