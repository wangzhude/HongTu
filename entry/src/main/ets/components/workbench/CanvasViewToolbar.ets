import { COLORS, formatZoomPercent } from '../../common/constants';
import { FONT_MONO } from '../../common/Fonts';
import { UI } from '../../common/UiTokens';
import { ActiveTool } from '../../workbench/WorkbenchModels';
import { MENU_ITEM_STYLE, menuCheckIcon, menuIcon, menuStyle, workbenchLuminousMenuOptions } from '../../common/WorkbenchMenuStyle';
import { hongTuThemeState } from '../../store/ThemeStore';
import { WorkbenchIcon } from './WorkbenchIcon';

/**
 * 桌面/平板横屏分组式功能区 Ribbon 工具栏（对齐参考布局第 2 行）
 *
 * 8 大专业版图功能分区：
 * 1. 文件 / 编辑（文件下拉、撤销/重做与编辑下拉）
 * 2. 选择工具（选择、框选、多边形、套索加选）
 * 3. 变换（移动、旋转、镜像、缩放偏置）
 * 4. 对齐（左齐、居中、右齐、上齐、下齐、等距分布）
 * 5. 布尔运算（合并、相减、相交、异或）
 * 6. 栅格与捕捉 + 正交约束（网格、捕捉下拉、90°正交）
 * 7. 检查（DRC 一键验证）
 * 8. 视图（缩放百分比下拉、放大、缩小、全图适配）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

@Component
export struct CanvasToolbarIconButton {
  @Prop icon: string = '';
  @Prop label: string = '';
  @Prop actionEnabled: boolean = false;
  @Prop active: boolean = false;
  @Prop danger: boolean = false;
  activateAction: () => void = () => {};

  private activate(): void {
    if (this.actionEnabled) this.activateAction();
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      WorkbenchIcon({
        name: this.icon,
        iconSize: 16,
        color: !this.actionEnabled
          ? COLORS.muted
          : (this.danger ? COLORS.danger : (this.active ? COLORS.primary : COLORS.ink))
      })
    }
    .width(30)
    .height(30)
    .padding(0)
    .backgroundColor(this.active ? COLORS.primarySoft : Color.Transparent)
    .border({ width: this.active ? 0.8 : 0, color: this.active ? COLORS.primary : Color.Transparent })
    .borderRadius(UI.controlRadius)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .enabled(this.actionEnabled)
    .opacity(this.actionEnabled ? 1 : 0.36)
    .focusable(false)
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText(this.label)
    .accessibilityDescription(this.label)
    .bindTips(this.label)
    .onClick(() => this.activate())
  }
}

@Component
struct RibbonCommandItem {
  @Prop icon: string = '';
  @Prop label: string = '';
  @Prop tip: string = '';
  @Prop active: boolean = false;
  @Prop actionEnabled: boolean = true;
  @Prop showChevron: boolean = false;
  @Prop badgeCount: number = 0;
  @Prop itemWidth: number = 42;
  activateAction: () => void = () => {};
  secondaryAction: (() => void) | null = null;

  build() {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 3 }) {
        Badge({
          count: this.badgeCount,
          maxCount: 99,
          position: BadgePosition.RightTop,
          style: { badgeColor: COLORS.danger, fontSize: 8.5, badgeSize: 13, color: Color.White }
        }) {
          Row() {
            WorkbenchIcon({
              name: this.icon,
              iconSize: 17,
              color: !this.actionEnabled ? COLORS.muted : (this.active ? COLORS.primary : COLORS.ink)
            })
          }
          .width(24)
          .height(20)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
        }

        Row({ space: 2 }) {
          Text(this.label)
            .fontSize(10.5)
            .fontWeight(this.active ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(!this.actionEnabled ? COLORS.muted : (this.active ? COLORS.primary : COLORS.ink))
            .maxLines(1)
          if (this.showChevron) {
            WorkbenchIcon({
              name: 'chevronDown',
              iconSize: 9,
              color: !this.actionEnabled ? COLORS.muted : (this.active ? COLORS.primary : COLORS.muted)
            })
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .constraintSize({ minWidth: this.itemWidth })
    .height(44)
    .padding({ left: 5, right: 5, top: 3, bottom: 3 })
    .backgroundColor(this.active ? COLORS.primarySoft : Color.Transparent)
    .border({
      width: this.active ? 0.8 : 0,
      color: this.active ? COLORS.primary : Color.Transparent,
      radius: UI.controlRadius
    })
    .borderRadius(UI.controlRadius)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .enabled(this.actionEnabled)
    .opacity(this.actionEnabled ? 1 : 0.38)
    .focusable(false)
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText(this.tip.length > 0 ? this.tip : this.label)
    .accessibilitySelected(this.active)
    .bindTips(this.tip.length > 0 ? this.tip : this.label)
    .onClick(() => {
      if (this.actionEnabled) {
        this.activateAction();
      }
    })
    .onMouse((event: MouseEvent) => {
      if (this.actionEnabled && this.secondaryAction !== null &&
        event.action === MouseAction.Press && event.button === MouseButton.Right) {
        event.stopPropagation();
        this.secondaryAction();
      }
    })
  }
}

@Component
struct RibbonDivider {
  build() {
    Divider()
      .vertical(true)
      .height(42)
      .color(COLORS.border)
      .margin({ left: 6, right: 6 })
  }
}

@Component
export struct CanvasViewToolbar {
  @Prop viewMode: string = '编辑';
  @Prop currentTool: ActiveTool = ActiveTool.Select;
  @Prop boxSelectRule: number = 0;
  @Prop zoomPercent: number = 100;
  @Prop canUndo: boolean = false;
  @Prop canRedo: boolean = false;
  @Prop editable: boolean = true;
  @Prop hasSelection: boolean = false;
  @Prop selectionCount: number = 0;
  @Prop moveToolActive: boolean = false;
  @Prop activeLayerNumber: number = 1;
  @Prop activeDatatype: number = 0;
  @Prop activeLayerColor: string = '#2984FF';
  @Prop activeLayerLabel: string = '';
  @Prop scopeText: string = '';
  @Prop compactMode: boolean = false;
  @Prop gridVisible: boolean = true;
  @Prop gridSnapEnabled: boolean = true;
  @Prop geometrySnapEnabled: boolean = true;
  @Prop routingModeLabel: string = '90°正交';
  @Prop routingLocked: boolean = true;
  @Prop multiSelectAdditive: boolean = false;
  @Prop drcIssueCount: number = 0;

  newFileAction: () => void = () => {};
  openFileAction: () => void = () => {};
  saveAction: () => void = () => {};
  saveAsAction: () => void = () => {};
  importMergeAction: () => void = () => {};
  shareLayoutAction: () => void = () => {};
  undoAction: () => void = () => {};
  redoAction: () => void = () => {};
  copyAction: () => void = () => {};
  pasteAction: () => void = () => {};
  duplicateAction: () => void = () => {};
  deleteAction: () => void = () => {};
  selectAllAction: () => void = () => {};
  clearSelectionAction: () => void = () => {};
  selectStandardToolAction: () => void = () => {};
  boxSelectToolAction: () => void = () => {};
  polygonToolAction: () => void = () => {};
  moveToolAction: () => void = () => {};
  rotate90Action: () => void = () => {};
  mirrorHAction: () => void = () => {};
  mirrorVAction: () => void = () => {};
  scaleAction: () => void = () => {};
  alignAction: (mode: string) => void = (_m: string) => {};
  distributeAction: (axis: 'horizontal' | 'vertical') => void = (_a: 'horizontal' | 'vertical') => {};
  booleanAction: (op: 'merge' | 'subtract' | 'intersect' | 'xor' | 'dialog') => void = (_op: 'merge' | 'subtract' | 'intersect' | 'xor' | 'dialog') => {};
  traceAction: () => void = () => {};
  runDrcAction: () => void = () => {};
  openLayerStyleAction: () => void = () => {};
  openPrecisionAction: () => void = () => {};
  zoomAction: (delta: number) => void = () => {};
  setZoomPercentAction: (percent: number) => void = (_p: number) => {};
  fitAction: () => void = () => {};
  resetViewAction: () => void = () => {};
  modeAction: (mode: string) => void = () => {};
  toggleGridVisibleAction: () => void = () => {};
  toggleGridSnapAction: () => void = () => {};
  toggleGeometrySnapAction: () => void = () => {};
  cycleRoutingModeAction: () => void = () => {};
  toggleMultiSelectAdditiveAction: () => void = () => {};

  private fileMenuSizing(): MenuItemOptions[] {
    return [
      { content: '新建版图', symbolStartIcon: menuIcon('new') },
      { content: '打开版图…', labelInfo: 'Ctrl+O', symbolStartIcon: menuIcon('open') },
      { content: '保存版图', labelInfo: 'Ctrl+S', symbolStartIcon: menuIcon('save') },
      { content: '版图另存为…', labelInfo: 'Ctrl+Shift+S', symbolStartIcon: menuIcon('saveAs') },
      { content: '导入合并版图…', symbolStartIcon: menuIcon('import') },
      { content: '分享版图快照…', symbolStartIcon: menuIcon('export') }
    ];
  }

  @Builder
  private buildFileMenu() {
    Menu() {
      MenuItemGroup({ header: '文件操作' }) {
        MenuItem({ content: '新建版图', symbolStartIcon: menuIcon('new') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.newFileAction())
        MenuItem({ content: '打开版图…', labelInfo: 'Ctrl+O', symbolStartIcon: menuIcon('open') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.openFileAction())
        MenuItem({ content: '保存版图', labelInfo: 'Ctrl+S', symbolStartIcon: menuIcon('save') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.saveAction())
        MenuItem({ content: '版图另存为…', labelInfo: 'Ctrl+Shift+S', symbolStartIcon: menuIcon('saveAs') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.saveAsAction())
        MenuItem({ content: '导入合并版图…', symbolStartIcon: menuIcon('import') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.importMergeAction())
        MenuItem({ content: '分享版图快照…', symbolStartIcon: menuIcon('export') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.shareLayoutAction())
      }
    }
    .attributeModifier(menuStyle(this.fileMenuSizing(), this.getUIContext()))
  }

  private editMenuSizing(): MenuItemOptions[] {
    return [
      { content: '复制选区', labelInfo: 'Ctrl+C', symbolStartIcon: menuIcon('copy') },
      { content: '粘贴图形', labelInfo: 'Ctrl+V', symbolStartIcon: menuIcon('paste') },
      { content: '原位复制+1', labelInfo: 'Ctrl+D', symbolStartIcon: menuIcon('new') },
      { content: '全选当前单元', labelInfo: 'Ctrl+A', symbolStartIcon: menuIcon('selectAll') },
      { content: '清空选区', labelInfo: 'Esc', symbolStartIcon: menuIcon('selectNone') },
      { content: '编辑模式（关闭则为只读）', symbolStartIcon: menuIcon('edit'), symbolEndIcon: menuCheckIcon(this.viewMode !== '查看') },
      { content: '删除选中图形', labelInfo: 'Del', symbolStartIcon: menuIcon('delete', true) }
    ];
  }

  @Builder
  private buildEditMenu() {
    Menu() {
      MenuItemGroup({ header: '编辑与选区' }) {
        MenuItem({ content: '复制选区', labelInfo: 'Ctrl+C', symbolStartIcon: menuIcon('copy') })
          .attributeModifier(MENU_ITEM_STYLE)
          .enabled(this.hasSelection)
          .onClick(() => this.copyAction())
        MenuItem({ content: '粘贴图形', labelInfo: 'Ctrl+V', symbolStartIcon: menuIcon('paste') })
          .attributeModifier(MENU_ITEM_STYLE)
          .enabled(this.editable)
          .onClick(() => this.pasteAction())
        MenuItem({ content: '原位复制+1', labelInfo: 'Ctrl+D', symbolStartIcon: menuIcon('new') })
          .attributeModifier(MENU_ITEM_STYLE)
          .enabled(this.editable && this.hasSelection)
          .onClick(() => this.duplicateAction())
        MenuItem({ content: '全选当前单元', labelInfo: 'Ctrl+A', symbolStartIcon: menuIcon('selectAll') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.selectAllAction())
        MenuItem({ content: '清空选区', labelInfo: 'Esc', symbolStartIcon: menuIcon('selectNone') })
          .attributeModifier(MENU_ITEM_STYLE)
          .enabled(this.hasSelection)
          .onClick(() => this.clearSelectionAction())
        MenuItem({ content: '编辑模式（关闭则为只读）', symbolStartIcon: menuIcon('edit'), symbolEndIcon: menuCheckIcon(this.viewMode !== '查看') })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.viewMode !== '查看')
          .onClick(() => this.modeAction(this.viewMode === '查看' ? '编辑' : '查看'))
      }
      MenuItemGroup() {
        MenuItem({ content: '删除选中图形', labelInfo: 'Del', symbolStartIcon: menuIcon('delete', true) })
          .attributeModifier(MENU_ITEM_STYLE)
          .enabled(this.editable && this.hasSelection)
          .onClick(() => this.deleteAction())
      }
    }
    .attributeModifier(menuStyle(this.editMenuSizing(), this.getUIContext()))
  }

  private snapMenuSizing(): MenuItemOptions[] {
    return [
      { content: '几何靶标捕捉（顶点/中点/交点/边）', symbolStartIcon: menuIcon('select'), symbolEndIcon: menuCheckIcon(this.geometrySnapEnabled) },
      { content: '网格步长对齐吸附', symbolStartIcon: menuIcon('grid'), symbolEndIcon: menuCheckIcon(this.gridSnapEnabled) },
      { content: '显示画布背景网格', labelInfo: 'G', symbolStartIcon: menuIcon('eye'), symbolEndIcon: menuCheckIcon(this.gridVisible) },
      { content: '电气网络连通追踪', symbolStartIcon: menuIcon('trace') }
    ];
  }

  @Builder
  private buildSnapMenu() {
    Menu() {
      MenuItemGroup({ header: '栅格与几何捕捉' }) {
        MenuItem({ content: '几何靶标捕捉（顶点/中点/交点/边）', symbolStartIcon: menuIcon('select'), symbolEndIcon: menuCheckIcon(this.geometrySnapEnabled) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.geometrySnapEnabled)
          .onClick(() => this.toggleGeometrySnapAction())
        MenuItem({ content: '网格步长对齐吸附', symbolStartIcon: menuIcon('grid'), symbolEndIcon: menuCheckIcon(this.gridSnapEnabled) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.gridSnapEnabled)
          .onClick(() => this.toggleGridSnapAction())
        MenuItem({ content: '显示画布背景网格', labelInfo: 'G', symbolStartIcon: menuIcon('eye'), symbolEndIcon: menuCheckIcon(this.gridVisible) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.gridVisible)
          .onClick(() => this.toggleGridVisibleAction())
        MenuItem({ content: '电气网络连通追踪', symbolStartIcon: menuIcon('trace') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.traceAction())
      }
    }
    .attributeModifier(menuStyle(this.snapMenuSizing(), this.getUIContext()))
  }

  private zoomMenuSizing(): MenuItemOptions[] {
    return [
      { content: '25%', symbolStartIcon: menuIcon('zoomOut') },
      { content: '50%', symbolStartIcon: menuIcon('zoomOut') },
      { content: '100%', symbolStartIcon: menuIcon('view') },
      { content: '200%', symbolStartIcon: menuIcon('zoomIn') },
      { content: '400%', symbolStartIcon: menuIcon('zoomIn') },
      { content: '适配全部版图', labelInfo: 'F', symbolStartIcon: menuIcon('view') },
      { content: '重置初始视图', symbolStartIcon: menuIcon('reset') }
    ];
  }

  @Builder
  private buildZoomMenu() {
    Menu() {
      MenuItemGroup({ header: '视图缩放比例' }) {
        ForEach([25, 50, 100, 200, 400], (pct: number) => {
          MenuItem({
            content: `${pct}%`,
            symbolStartIcon: menuIcon(pct < 100 ? 'zoomOut' : (pct > 100 ? 'zoomIn' : 'view')),
            symbolEndIcon: menuCheckIcon(Math.abs(this.zoomPercent - pct) < 0.5)
          })
            .attributeModifier(MENU_ITEM_STYLE)
            .selected(Math.abs(this.zoomPercent - pct) < 0.5)
            .onClick(() => this.setZoomPercentAction(pct))
        }, (pct: number): string => `z_${pct}_${Math.round(this.zoomPercent)}`)
      }
      MenuItemGroup({ header: '视口定位' }) {
        MenuItem({ content: '适配全部版图', labelInfo: 'F', symbolStartIcon: menuIcon('view') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.fitAction())
        MenuItem({ content: '重置初始视图', symbolStartIcon: menuIcon('reset') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.resetViewAction())
      }
    }
    .attributeModifier(menuStyle(this.zoomMenuSizing(), this.getUIContext()))
  }

  @Builder
  private groupCaption(text: string) {
    Text(text)
      .fontSize(9.5)
      .fontColor(COLORS.muted)
      .maxLines(1)
  }

  build() {
    Scroll() {
      Row({ space: 0 }) {
        // 1. 文件与编辑分区
        Column({ space: 2 }) {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 3 }) {
              WorkbenchIcon({ name: 'document', iconSize: 17, color: COLORS.ink })
              Row({ space: 2 }) {
                Text('文件')
                  .fontSize(10.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(COLORS.ink)
                WorkbenchIcon({ name: 'chevronDown', iconSize: 9, color: COLORS.muted })
              }.alignItems(VerticalAlign.Center)
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
          .width(46)
          .height(44)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .focusable(false)
          .hoverEffect(HoverEffect.Highlight)
          .bindTips('新建、打开、保存与导出文件')
          .bindMenu(this.buildFileMenu, workbenchLuminousMenuOptions())
          Text(' ').fontSize(9.5)
        }
        .alignItems(HorizontalAlign.Center)

        RibbonDivider()

        Column({ space: 2 }) {
          Row({ space: 2 }) {
            CanvasToolbarIconButton({
              icon: 'undo',
              label: '撤销 (Ctrl+Z)',
              actionEnabled: this.canUndo,
              activateAction: this.undoAction
            })
            CanvasToolbarIconButton({
              icon: 'redo',
              label: '重做 (Ctrl+Shift+Z)',
              actionEnabled: this.canRedo,
              activateAction: this.redoAction
            })
          }
          .height(44)
          .alignItems(VerticalAlign.Center)

          Button({ type: ButtonType.Normal }) {
            Row({ space: 2 }) {
              Text('编辑')
                .fontSize(9.5)
                .fontColor(COLORS.muted)
              WorkbenchIcon({ name: 'chevronDown', iconSize: 8.5, color: COLORS.muted })
            }.alignItems(VerticalAlign.Center)
          }
          .height(14)
          .padding({ left: 4, right: 4 })
          .backgroundColor(Color.Transparent)
          .borderRadius(4)
          .focusable(false)
          .bindMenu(this.buildEditMenu, workbenchLuminousMenuOptions())
        }
        .alignItems(HorizontalAlign.Center)

        RibbonDivider()

        // 2. 选择工具（选择 / 框选 / 多边形 / 套索）
        Column({ space: 2 }) {
          Row({ space: 3 }) {
            RibbonCommandItem({
              icon: 'select',
              label: '选择',
              tip: '标准点选与智能框选 (S)',
              active: this.currentTool === ActiveTool.Select && this.boxSelectRule === 0 && !this.multiSelectAdditive,
              actionEnabled: true,
              activateAction: () => this.selectStandardToolAction()
            })
            RibbonCommandItem({
              icon: 'boxSelect',
              label: '框选',
              tip: this.boxSelectRule === 1 ? '框选模式：相交即选（再点切全包含）' : (this.boxSelectRule === 2 ? '框选模式：全包含（再点恢复智能）' : '切换框选规则（相交 / 全包）'),
              active: this.currentTool === ActiveTool.Select && this.boxSelectRule !== 0,
              actionEnabled: true,
              activateAction: () => this.boxSelectToolAction()
            })
            RibbonCommandItem({
              icon: 'polygon',
              label: '多边形',
              tip: '多边形绘制与区域创建 (P)',
              active: this.currentTool === ActiveTool.Polygon,
              actionEnabled: this.editable,
              activateAction: () => this.polygonToolAction()
            })
            RibbonCommandItem({
              icon: 'lasso',
              label: '套索',
              tip: '连续累加选择模式（免按 Shift 叠加点选/框选）',
              active: this.multiSelectAdditive,
              actionEnabled: true,
              activateAction: () => this.toggleMultiSelectAdditiveAction()
            })
          }
          this.groupCaption('选择工具')
        }
        .alignItems(HorizontalAlign.Center)

        RibbonDivider()

        // 3. 变换（移动 / 旋转 / 镜像 / 缩放）
        Column({ space: 2 }) {
          Row({ space: 3 }) {
            RibbonCommandItem({
              icon: 'move',
              label: '移动',
              tip: '移动图形 (M)',
              active: this.moveToolActive,
              actionEnabled: this.editable,
              activateAction: () => this.moveToolAction()
            })
            RibbonCommandItem({
              icon: 'rotate',
              label: '旋转',
              tip: '逆时针旋转 90° (R)',
              active: false,
              actionEnabled: this.editable && this.hasSelection,
              activateAction: () => this.rotate90Action()
            })
            RibbonCommandItem({
              icon: 'mirror',
              label: '镜像',
              tip: '水平镜像翻转（右键执行垂直镜像）',
              active: false,
              actionEnabled: this.editable && this.hasSelection,
              activateAction: () => this.mirrorHAction(),
              secondaryAction: () => this.mirrorVAction()
            })
            RibbonCommandItem({
              icon: 'scale',
              label: '缩放',
              tip: '图形边界偏置缩放 (Size Shapes)…',
              active: false,
              actionEnabled: this.editable && this.hasSelection,
              activateAction: () => this.scaleAction()
            })
          }
          this.groupCaption('变换')
        }
        .alignItems(HorizontalAlign.Center)

        RibbonDivider()

        // 4. 对齐（左齐 / 居中 / 右齐 / 上齐 / 下齐 / 等距）
        Column({ space: 2 }) {
          Row({ space: 2 }) {
            RibbonCommandItem({
              icon: 'alignLeft',
              label: '左齐',
              tip: '左边界对齐（需选中 ≥2 项）',
              itemWidth: 38,
              actionEnabled: this.editable && this.selectionCount >= 2,
              activateAction: () => this.alignAction('left')
            })
            RibbonCommandItem({
              icon: 'alignCenter',
              label: '居中',
              tip: '水平中心对齐（右键执行垂直居中）',
              itemWidth: 38,
              actionEnabled: this.editable && this.selectionCount >= 2,
              activateAction: () => this.alignAction('center_h'),
              secondaryAction: () => this.alignAction('center_v')
            })
            RibbonCommandItem({
              icon: 'alignRight',
              label: '右齐',
              tip: '右边界对齐（需选中 ≥2 项）',
              itemWidth: 38,
              actionEnabled: this.editable && this.selectionCount >= 2,
              activateAction: () => this.alignAction('right')
            })
            RibbonCommandItem({
              icon: 'alignTop',
              label: '上齐',
              tip: '上边界对齐（需选中 ≥2 项）',
              itemWidth: 38,
              actionEnabled: this.editable && this.selectionCount >= 2,
              activateAction: () => this.alignAction('top')
            })
            RibbonCommandItem({
              icon: 'alignBottom',
              label: '下齐',
              tip: '下边界对齐（需选中 ≥2 项）',
              itemWidth: 38,
              actionEnabled: this.editable && this.selectionCount >= 2,
              activateAction: () => this.alignAction('bottom')
            })
            RibbonCommandItem({
              icon: 'distribute',
              label: '等距',
              tip: '水平等距分布（需选中 ≥3 项，右键垂直等距）',
              itemWidth: 38,
              actionEnabled: this.editable && this.selectionCount >= 3,
              activateAction: () => this.distributeAction('horizontal'),
              secondaryAction: () => this.distributeAction('vertical')
            })
          }
          this.groupCaption('对齐')
        }
        .alignItems(HorizontalAlign.Center)

        RibbonDivider()

        // 5. 布尔运算（合并 / 相减 / 相交 / 异或）
        Column({ space: 2 }) {
          Row({ space: 3 }) {
            RibbonCommandItem({
              icon: 'union',
              label: '合并',
              tip: '布尔合并 Union（右键打开布尔预览与图层表达式）',
              itemWidth: 40,
              actionEnabled: this.editable && this.selectionCount >= 2,
              activateAction: () => this.booleanAction('merge'),
              secondaryAction: () => this.booleanAction('dialog')
            })
            RibbonCommandItem({
              icon: 'subtract',
              label: '相减',
              tip: '布尔相减 Subtract (A - B)',
              itemWidth: 40,
              actionEnabled: this.editable && this.selectionCount >= 2,
              activateAction: () => this.booleanAction('subtract'),
              secondaryAction: () => this.booleanAction('dialog')
            })
            RibbonCommandItem({
              icon: 'intersect',
              label: '相交',
              tip: '布尔相交 Intersect (A ∩ B)',
              itemWidth: 40,
              actionEnabled: this.editable && this.selectionCount >= 2,
              activateAction: () => this.booleanAction('intersect'),
              secondaryAction: () => this.booleanAction('dialog')
            })
            RibbonCommandItem({
              icon: 'xor',
              label: '异或',
              tip: '布尔异或 XOR (A ⊕ B)',
              itemWidth: 40,
              actionEnabled: this.editable && this.selectionCount >= 2,
              activateAction: () => this.booleanAction('xor'),
              secondaryAction: () => this.booleanAction('dialog')
            })
          }
          this.groupCaption('布尔运算')
        }
        .alignItems(HorizontalAlign.Center)

        RibbonDivider()

        // 6. 栅格与捕捉
        Column({ space: 2 }) {
          Row({ space: 3 }) {
            RibbonCommandItem({
              icon: 'grid',
              label: '网格',
              tip: '显示或隐藏画布背景网格 (G)',
              active: this.gridVisible,
              itemWidth: 42,
              actionEnabled: true,
              activateAction: () => this.toggleGridVisibleAction()
            })
            Button({ type: ButtonType.Normal }) {
              Column({ space: 3 }) {
                Row() {
                  WorkbenchIcon({
                    name: 'magnet',
                    iconSize: 17,
                    color: this.geometrySnapEnabled ? COLORS.primary : COLORS.ink
                  })
                }.width(24).height(20).justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
                Row({ space: 2 }) {
                  Text('捕捉')
                    .fontSize(10.5)
                    .fontWeight(this.geometrySnapEnabled ? FontWeight.Bold : FontWeight.Medium)
                    .fontColor(this.geometrySnapEnabled ? COLORS.primary : COLORS.ink)
                  WorkbenchIcon({
                    name: 'chevronDown',
                    iconSize: 9,
                    color: this.geometrySnapEnabled ? COLORS.primary : COLORS.muted
                  })
                }.alignItems(VerticalAlign.Center)
              }.justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
            }
            .constraintSize({ minWidth: 46 })
            .height(44)
            .padding({ left: 5, right: 5, top: 3, bottom: 3 })
            .backgroundColor(this.geometrySnapEnabled ? COLORS.primarySoft : Color.Transparent)
            .border({
              width: this.geometrySnapEnabled ? 0.8 : 0,
              color: this.geometrySnapEnabled ? COLORS.primary : Color.Transparent,
              radius: UI.controlRadius
            })
            .borderRadius(UI.controlRadius)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .hoverEffect(HoverEffect.Highlight)
            .bindTips('几何捕捉与网格步长吸附选项')
            .bindMenu(this.buildSnapMenu, workbenchLuminousMenuOptions())
          }
          this.groupCaption('栅格与捕捉')
        }
        .alignItems(HorizontalAlign.Center)

        RibbonDivider()

        // 7. 走线正交约束
        Column({ space: 2 }) {
          RibbonCommandItem({
            icon: 'ortho',
            label: this.routingModeLabel,
            tip: '点击切换走线约束：90°正交 / 45°斜交 / 自由角',
            active: this.routingLocked,
            itemWidth: 56,
            actionEnabled: true,
            activateAction: () => this.cycleRoutingModeAction()
          })
          Text(' ').fontSize(9.5)
        }
        .alignItems(HorizontalAlign.Center)

        RibbonDivider()

        // 8. DRC 检查
        Column({ space: 2 }) {
          RibbonCommandItem({
            icon: 'drcShield',
            label: 'DRC',
            tip: '运行设计规则检查 (DRC)',
            active: this.drcIssueCount > 0,
            badgeCount: this.drcIssueCount,
            itemWidth: 44,
            actionEnabled: true,
            activateAction: () => this.runDrcAction()
          })
          this.groupCaption('检查')
        }
        .alignItems(HorizontalAlign.Center)

        RibbonDivider()

        // 9. 视图缩放与全图适配
        Column({ space: 2 }) {
          Row({ space: 4 }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 5 }) {
                WorkbenchIcon({ name: 'search', iconSize: 13, color: COLORS.muted })
                Text(formatZoomPercent(this.zoomPercent))
                  .fontSize(11.5)
                  .fontFamily(FONT_MONO)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(COLORS.ink)
                WorkbenchIcon({ name: 'chevronDown', iconSize: 10, color: COLORS.muted })
              }
              .alignItems(VerticalAlign.Center)
            }
            .height(32)
            .padding({ left: 9, right: 8 })
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 0.8, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .hoverEffect(HoverEffect.Highlight)
            .bindTips('选择预设缩放比例')
            .bindMenu(this.buildZoomMenu, workbenchLuminousMenuOptions())

            CanvasToolbarIconButton({
              icon: 'loupe',
              label: '放大视口 (])',
              actionEnabled: true,
              activateAction: () => this.zoomAction(1)
            })
            CanvasToolbarIconButton({
              icon: 'zoomOut',
              label: '缩小视口 ([)',
              actionEnabled: true,
              activateAction: () => this.zoomAction(-1)
            })
            CanvasToolbarIconButton({
              icon: 'fit',
              label: '适配全部版图 (F)',
              actionEnabled: true,
              activateAction: () => this.fitAction()
            })
          }
          .height(44)
          .alignItems(VerticalAlign.Center)

          this.groupCaption('视图')
        }
        .alignItems(HorizontalAlign.Center)
      }
      .padding({ left: 10, right: 14, top: 4, bottom: 3 })
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .height(66)
    .align(Alignment.Start)
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { bottom: 0.8 }, color: COLORS.border })
  }
}
