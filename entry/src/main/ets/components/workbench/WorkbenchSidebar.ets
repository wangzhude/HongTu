import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { UiLayer, LayerGroup } from '../../common/types';
import { COLORS } from '../../common/constants';
import { RADIUS } from '../../common/MaterialTokens';
import { FONT_MONO } from '../../common/Fonts';
import { viewService } from '../../services/ViewService';
import { Shape } from '../../models/GdsiiData';
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
 * 鸿图左侧 Toolbox（受控 `StableSegmentButton` + 原生光感菜单收口 + 纯矢量 Cell 节点图标）
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

enum ToolboxTab {
  Layers = 0,
  Cells = 1,
}

@Component
export struct WorkbenchSidebar {
  @Prop @Watch('onLayerDataChanged') layers: UiLayer[] = [];
  @Link @Watch('onLayerDataChanged') shapes: Shape[];
  @Prop @Watch('onLayerDataChanged') selectedLayerNumber: number = -1;
  @Prop @Watch('onLayerDataChanged') selectedDatatype: number = 0;
  @Prop sidebarWidth: number = 220;
  @Prop visible: boolean = true;
  @Prop showShortcutFooter: boolean = true;
  @Prop @Watch('onPresetNamesChanged') presetNames: string[] = [];
  @State selectedPresetName: string = '';

  @Prop cellTree: CellTreeNode[] = [];
  @Prop cellDefinitionCount: number = -1;
  @Prop currentTopCellId: number = 0;

  @State @Watch('onLayerDataChanged') searchKey: string = '';
  private searchDebounceTimer: number = -1;

  @State activeTab: ToolboxTab = ToolboxTab.Layers;

  private layerDataSource: ArrayDataSource<UiLayer> = new ArrayDataSource<UiLayer>();

  toggleLayerAction: (layerNumber: number, visible: boolean, datatype: number) => void = () => {};
  selectLayerAction: (layer: UiLayer) => void = () => {};
  styleLayerAction: (layer: UiLayer) => void = () => {};
  openShortcutAction: () => void = () => {};
  setTopCellAction: (cellId: number, cellName: string) => void = () => {};
  newCellAction: () => void = () => {};
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

  private filteredLayers(): UiLayer[] {
    if (this.searchKey.length === 0) {
      return this.layers;
    }
    const key: string = this.searchKey.toLowerCase();
    const result: UiLayer[] = [];
    for (let i = 0; i < this.layers.length; i++) {
      const layer: UiLayer = this.layers[i];
      if (layer.chineseName.toLowerCase().includes(key) ||
        layer.englishName.toLowerCase().includes(key) ||
        `${layer.layerNumber}/${layer.datatype}`.includes(key)) {
        result.push(layer);
      }
    }
    return result;
  }

  private buildSidebarSegmentItems(): SegmentButtonItemTuple {
    const items: [SegmentButtonTextItem, SegmentButtonTextItem] = [
      { text: '图层' },
      { text: 'Cell' }
    ];
    return items;
  }

  build() {
    Column() {
      Row() {
        Text('图层与层级').fontSize(16).fontWeight(FontWeight.Bold).fontColor(COLORS.ink)
        Blank()
        Text(`${this.layers.length}`).fontSize(UI.fontCaption).fontColor(COLORS.muted)
        if (this.activeTab === ToolboxTab.Layers) {
          Button({ type: ButtonType.Circle }) {
            WorkbenchIcon({ name: 'menu', iconSize: 16, color: COLORS.ink })
          }
          .id('layer-panel-menu')
          .width(UI.compactControlHeight)
          .height(UI.compactControlHeight)
          .padding(0)
          .margin({ left: 6 })
          .backgroundColor(COLORS.surfaceMuted)
          .accessibilityText('图层面板菜单')
          .bindTips('导入或导出图层属性')
          .bindMenu(this.buildLypContextMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
        }
      }.width('100%').height(42).padding({ left: 4, right: 4 })

      Row() {
        StableSegmentButton({
          items: this.buildSidebarSegmentItems(),
          selectedIndex: this.activeTab as number,
          onItemClicked: (tab: number) => { this.activeTab = tab as ToolboxTab; },
          fontColor: COLORS.muted,
          selectedFontColor: Color.White,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primary,
          fontSizeFp: UI.fontBody,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 34,
          itemMinHeight: 28
        })
      }
      .width('100%')
      .height(UI.controlHeight)
      .margin({ bottom: 4 })

      if (this.activeTab === ToolboxTab.Layers) {
        this.buildLayersTab()
      } else {
        this.buildCellsTab()
      }

      if (this.showShortcutFooter) {
        Button({ type: ButtonType.Normal }) {
          Row() {
            WorkbenchIcon({ name: 'info', iconSize: 16, color: COLORS.primary })
            Text('快捷键')
              .fontSize(12)
              .fontColor(COLORS.primary)
              .fontWeight(FontWeight.Medium)
              .margin({ left: 8 })
            Blank()
            Text('S · B · P · L ...')
              .fontSize(9)
              .fontColor(COLORS.muted)
              .fontFamily(FONT_MONO)
          }
          .width('100%')
        }
        .width('100%')
        .height(36)
        .padding({ left: 10, right: 10 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .attributeModifier(hongTuThemeState.luminousPointLightModifier())
        .accessibilityText('打开快捷键设置')
        .onClick(() => {
          this.openShortcutAction();
        })
      }
    }
    .width(this.sidebarWidth)
    .height('100%')
    .padding({ left: 12, right: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { right: 0.8 }, color: COLORS.border })
  }

  @Builder
  buildLypContextMenu() {
    Menu() {
      MenuItem({ content: '导入 .lyp 图层属性…', symbolStartIcon: menuIcon('import') })
        .id('import-layer-profile')
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => {
          this.importLypAction();
        })
      MenuItem({ content: '导出 .lyp 图层属性…', symbolStartIcon: menuIcon('export') })
        .id('export-layer-profile')
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => {
          this.exportLypAction();
        })
    }
    .attributeModifier(menuStyle([
      { content: '导入 .lyp 图层属性…', symbolStartIcon: menuIcon('import') },
      { content: '导出 .lyp 图层属性…', symbolStartIcon: menuIcon('export') }
    ], this.getUIContext()))
  }

  @Builder
  buildPresetMenu() {
    Menu() {
      MenuItem({ content: '保存当前视图…', symbolStartIcon: menuIcon('save') })
        .id('save-view-preset').attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => this.savePresetAction())
      MenuItem({ content: '应用选中预设', symbolStartIcon: menuIcon('preset') })
        .id('apply-view-preset').attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.selectedPresetName.length > 0)
        .onClick(() => this.applyPresetAction(this.selectedPresetName))
      MenuItemGroup() {
        MenuItem({ content: '删除选中预设', symbolStartIcon: menuIcon('delete', true) })
          .id('delete-view-preset').attributeModifier(MENU_DANGER_ITEM_STYLE)
          .enabled(this.selectedPresetName.length > 0)
          .onClick(() => this.deletePresetAction(this.selectedPresetName))
      }
    }.attributeModifier(menuStyle([
      { content: '保存当前视图…', symbolStartIcon: menuIcon('save') },
      { content: '应用选中预设', symbolStartIcon: menuIcon('preset') },
      { content: '删除选中预设', symbolStartIcon: menuIcon('delete', true) }
    ], this.getUIContext()))
  }

  @Builder
  buildLayersTab() {
    Column() {
      Search({ value: this.searchKey, placeholder: '搜索图层' })
        .width('100%')
        .height(UI.fieldHeight)
        .textFont({ size: UI.fontBody })
        .placeholderFont({ size: UI.fontBody })
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .searchIcon({ size: 16, color: COLORS.muted })
        .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 14, color: COLORS.muted } })
        .backgroundColor(COLORS.surface)
        .border({ width: 1, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .margin({ top: 8, bottom: 6 })
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
          }, 200);
        })

      Row({ space: 6 }) {
        Select(this.presetNames.map((name: string): SelectOption => ({ value: name })))
          .id('view-preset-select')
          .selected(this.presetNames.indexOf(this.selectedPresetName))
          .value(this.selectedPresetName || '尚无视图预设')
          .enabled(this.presetNames.length > 0)
          .layoutWeight(1).height(UI.fieldHeight).borderRadius(UI.controlRadius)
          .font({ size: UI.fontBody }).fontColor(COLORS.ink)
          .accessibilityText('视图预设')
          .onSelect((index: number) => { this.selectedPresetName = this.presetNames[index] ?? ''; })
        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({ name: 'menu', iconSize: 18, color: COLORS.ink })
        }
        .id('view-preset-menu')
        .width(UI.controlHeight)
        .height(UI.controlHeight)
        .padding(0)
        .backgroundColor(COLORS.surfaceMuted)
        .borderRadius(UI.controlRadius)
        .accessibilityText('视图预设操作')
        .bindTips('保存、应用或删除视图预设')
        .bindMenu(this.buildPresetMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
      }.width('100%').margin({ bottom: 8 })

      Row() {
        Text('可见').width(32).textAlign(TextAlign.Center).fontSize(10).fontColor(COLORS.muted)
        Text('名称').layoutWeight(1).padding({ left: 8 }).fontSize(10).fontColor(COLORS.muted)
        Text('层/数据').width(54).fontSize(10).fontColor(COLORS.muted)
        if (this.sidebarWidth >= 260) {
          Text('图形数').width(42).textAlign(TextAlign.End).fontSize(10).fontColor(COLORS.muted)
        }
        Row().width(24)
      }.width('100%').height(32).padding({ left: 4, right: 4 })
        .backgroundColor(COLORS.surfaceMuted).borderRadius(6)

      List() {
        LazyForEach(this.layerDataSource, (layer: UiLayer) => {
          ListItem() {
            LayerToolboxRow({
              layer: layer,
              elementCount: layer.elementCount,
              compactRows: this.sidebarWidth < 260,
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
      .cachedCount(12)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)
    }
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  buildCellsTab() {
    Column() {
      Row() {
        Text(`共 ${this.countCells()} 个 Cell 定义`)
          .fontSize(10)
          .fontColor(COLORS.muted)
          .bindTips('按 Cell 定义去重统计；共享 Cell 在树中可出现多次')
        Blank()
        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({ name: 'plus', iconSize: 14, color: COLORS.primary })
        }
        .width(UI.compactControlHeight)
        .height(UI.compactControlHeight)
        .padding(0)
        .borderRadius(RADIUS.sm)
        .backgroundColor(COLORS.primarySoft)
        .accessibilityText('新建 Cell')
        .bindTips('新建 Cell')
        .onClick(() => this.newCellAction())
      }
      .width('100%')
      .height(30)
      .padding({ left: 4, right: 4 })
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.cellTree.length === 0) {
        Column() {
          Text('暂无 Cell 数据')
            .fontSize(11)
            .fontColor(COLORS.muted)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        List() {
          ForEach(this.cellTree, (node: CellTreeNode) => {
            this.buildCellNodeRow(node)
          }, (node: CellTreeNode) => this.cellRowKey(node))
        }
        .layoutWeight(1)
        .width('100%')
        .cachedCount(10)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(true)
      }
    }
    .layoutWeight(1)
    .width('100%')
  }

  private cellRowKey(node: CellTreeNode): string {
    return `${node.key()}:${node.cellName}:${node.referenceCount}:${node.expanded}:${node.children.length}`;
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
    return Math.min(depth * 14, Math.max(0, this.sidebarWidth - (196 + UI.compactControlHeight - 14)));
  }

  @Builder
  buildCellNodeRow(node: CellTreeNode) {
    ListItem() {
      Row() {
        Row().width(this.cellRowIndent(node.depth))

        if (node.children.length > 0) {
          Button({ type: ButtonType.Normal }) {
            WorkbenchIcon({
              name: node.expanded ? 'chevronDown' : 'chevronRight',
              iconSize: 13,
              color: COLORS.primary
            })
          }
          .width(UI.compactControlHeight)
          .height(UI.compactControlHeight)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .borderRadius(UI.controlRadius)
          .accessibilityText(`${node.expanded ? '折叠' : '展开'} Cell ${node.cellName}`)
          .bindTips(`${node.expanded ? '折叠' : '展开'} Cell ${node.cellName}`)
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onMouse((event: MouseEvent) => event.stopPropagation())
          .onClick(() => this.toggleCellExpanded(node.path))
        } else {
          Row().width(UI.compactControlHeight)
        }

        Row() {
          DrawnStatusIcon({
            kind: node.cellId === this.currentTopCellId ? 'radio' : 'active',
            iconSize: 12,
            strokeColor: node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.muted,
            showSoftPlate: false
          })
        }
        .margin({ right: 5 })

        Text(node.cellName)
          .fontSize(12)
          .fontColor(node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.ink)
          .fontWeight(node.cellId === this.currentTopCellId ? FontWeight.Medium : FontWeight.Normal)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .bindTips(node.cellName)

        if (node.referenceCount > 0) {
          Text(`引用 ${node.referenceCount}`)
            .fontSize(9)
            .fontColor(COLORS.muted)
            .fontFamily(FONT_MONO)
            .constraintSize({ maxWidth: 52 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .accessibilityText(`${node.cellName} 在父 Cell 中有 ${node.referenceCount} 条直接引用记录`)
            .bindTips('父 Cell 中的直接引用记录数')
        }
        Button('进入', { type: ButtonType.Normal })
          .width(40).height(UI.compactControlHeight).fontSize(UI.fontCaption).padding(0)
          .margin({ left: 4 }).fontColor(COLORS.primary).backgroundColor(Color.Transparent)
          .borderRadius(UI.controlRadius)
          .accessibilityText(`进入 Cell ${node.cellName}`)
          .bindTips(`进入 Cell ${node.cellName} 的共享定义`)
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onMouse((event: MouseEvent) => event.stopPropagation())
          .onClick(() => this.setTopCellAction(node.cellId, node.cellName))
      }
      .width('100%')
      .height(UI.compactControlHeight)
      .padding({ left: 4, right: 6 })
      .borderRadius(RADIUS.sm)
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
        MenuItem({ content: '进入该 Cell', symbolStartIcon: menuIcon('cell'),
          symbolEndIcon: menuCheckIcon(node.cellId === this.currentTopCellId) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(node.cellId === this.currentTopCellId)
          .onClick(() => { this.setTopCellAction(node.cellId, node.cellName); })
        MenuItem({ content: '新建 Cell…', symbolStartIcon: menuIcon('new') })
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
    .attributeModifier(menuStyle([
      { content: '进入该 Cell', symbolStartIcon: menuIcon('cell'),
        symbolEndIcon: menuCheckIcon(node.cellId === this.currentTopCellId) },
      { content: '新建 Cell…', symbolStartIcon: menuIcon('new') },
      { content: '重命名 Cell…', symbolStartIcon: menuIcon('rename') },
      { content: '展开全部实例…', symbolStartIcon: menuIcon('flatten') },
      { content: '删除 Cell', symbolStartIcon: menuIcon('delete', true) }
    ], this.getUIContext()))
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
  @Prop compactRows: boolean = false;
  toggleAction: (layerNumber: number, datatype: number) => void = () => {};
  selectAction: (layer: UiLayer) => void = () => {};
  styleLayerAction: (layer: UiLayer) => void = () => {};
  lockAction: (layerNumber: number, datatype: number) => void = () => {};
  selectableAction: (layerNumber: number, datatype: number, selectable: boolean) => void = () => {};
  selectAllOnLayerAction: (layerNumber: number, datatype: number) => void = () => {};

  build() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({ name: this.layer.visible ? 'eye' : 'eyeOff', iconSize: 18,
          color: this.layer.visible ? COLORS.primary : COLORS.muted })
      }
      .width(32)
      .height(36)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(RADIUS.sm)
      .hitTestBehavior(HitTestMode.Block)
      .accessibilityText(this.layer.visible ? '隐藏图层' : '显示图层')
      .bindTips(this.layer.visible ? '隐藏图层' : '显示图层')
      .onClick(() => {
        this.toggleAction(this.layer.layerNumber, this.layer.datatype);
      })
      Button({ type: ButtonType.Normal }) {
        Row().width(16).height(16).borderRadius(RADIUS.xs).backgroundColor(this.layer.color)
          .border({ width: 0.8, color: COLORS.border })
          .opacity(this.layer.visible ? 1.0 : 0.35)
      }
      .width(26).height(26).padding(0).margin({ left: 4, right: 4 })
      .backgroundColor(Color.Transparent).borderRadius(RADIUS.xs)
      .hitTestBehavior(HitTestMode.Block)
      .accessibilityText(`设置 L${this.layer.layerNumber}/D${this.layer.datatype} 图层颜色与填充样式`)
      .bindTips('点击修改图层颜色、线型与填充')
      .onClick(() => {
        this.selectAction(this.layer);
        this.styleLayerAction(this.layer);
      })
      Text(this.layer.chineseName).fontSize(12)
        .fontColor(this.isActive ? COLORS.primary : (this.layer.visible ? COLORS.ink : COLORS.muted))
        .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(`${this.layer.layerNumber}/${this.layer.datatype}`).fontSize(11)
        .fontColor(this.isActive ? COLORS.primary : COLORS.muted).fontFamily(FONT_MONO).width(54)
      if (!this.compactRows) {
        Text(this.elementCount.toString()).fontSize(11)
          .fontColor(this.isActive ? COLORS.primary : COLORS.muted).fontFamily(FONT_MONO)
          .width(42).textAlign(TextAlign.End)
      }
      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({ name: 'menu', iconSize: 14,
          color: this.layer.locked === true ? COLORS.warning : COLORS.muted })
      }
      .width(24)
      .height(36)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .borderRadius(RADIUS.sm)
      .hitTestBehavior(HitTestMode.Block)
      .accessibilityText(`图层操作 L${this.layer.layerNumber}/D${this.layer.datatype}`)
      .bindTips(this.layer.locked === true ? '图层已锁定 · 更多操作' : '样式、选择与锁定')
      .bindMenu(this.buildLayerContextMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
    }
    .width('100%')
    .height(46)
    .padding({ left: 4, right: 4 })
    .borderRadius(RADIUS.sm)
    .animation(null)
    .backgroundColor(this.isActive ? COLORS.primarySoft : Color.Transparent)
    .animation({ duration: this.reduceMotion ? 0 : MOTION.feedback, curve: feedbackCurve() })
    .border({ width: { bottom: 0.7 }, color: this.isActive ? Color.Transparent : COLORS.border })
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
        MenuItem({ content: '图层样式…', symbolStartIcon: menuIcon('style') })
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
        MenuItem({ content: '设为当前层', symbolStartIcon: menuIcon('layer'),
          symbolEndIcon: menuCheckIcon(this.isActive) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.isActive)
          .onClick(() => { this.selectAction(this.layer); })
        MenuItem({ content: '选择该层全部图形', symbolStartIcon: menuIcon('selectAll') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.selectAllOnLayerAction(this.layer.layerNumber, this.layer.datatype); })
      }
    }
    .attributeModifier(menuStyle([
      { content: '图层样式…', symbolStartIcon: menuIcon('style') },
      { content: '显示图层', symbolStartIcon: menuIcon('eye'), symbolEndIcon: menuCheckIcon(this.layer.visible) },
      { content: '锁定图层', symbolStartIcon: menuIcon('lock'), symbolEndIcon: menuCheckIcon(this.layer.locked === true) },
      { content: '允许选择图层', symbolStartIcon: menuIcon('select'), symbolEndIcon: menuCheckIcon(this.layer.selectable !== false) },
      { content: '设为当前层', symbolStartIcon: menuIcon('layer'), symbolEndIcon: menuCheckIcon(this.isActive) },
      { content: '选择该层全部图形', symbolStartIcon: menuIcon('selectAll') }
    ], this.getUIContext()))
  }
}
