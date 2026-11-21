import { HdsNavigationMenuItemOptions, IconStyleMode } from '@kit.UIDesignKit';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { WorkbenchIcon } from './WorkbenchIcon';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { feedbackCurve, MOTION } from '../../common/Motion';
import { AnimPress } from '../../store/AnimationTokens';
import { RecentFile } from '../../workbench/WorkbenchModels';
import { resolveRecentFileMetadata, RecentFileSummaryMeta } from '../../services/FileImportService';
import { CellTreeNode } from './CellTreePanel';
import { AppNavigationShell } from '../AppNavigationShell';
import { StableSegmentButton } from '../StableSegmentButton';
import { hongTuThemeState } from '../../store/ThemeStore';
import {
  DEFAULT_RESPONSIVE_SNAPSHOT,
  getFloatingTabBottomSpacer,
  ResponsiveHeightClass,
  RESPONSIVE_FONT_SCALE_KEY,
  RESPONSIVE_HEIGHT_CLASS_KEY
} from '../../store/ResponsiveStore';

export const ACTIVE_LAYOUT_STAGE_GEOMETRY_ID: string = 'hongtu-active-layout-stage';

const ROW_DOUBLE_TAP_MIN_MS: number = 70;
const ROW_DOUBLE_TAP_MAX_MS: number = 350;
const ROW_SCROLL_SLOP_VP: number = 8;

enum DataTab {
  Files = 0,
  Cells = 1,
  History = 2,
}

enum FileDetailMetric {
  Format = 0,
  TopCell = 1,
  CellCount = 2,
  FileSize = 3,
}

interface DataMetricSpec {
  label: string;
  value: string;
  iconName?: string;
}

interface DataEmptyStateSpec {
  title: string;
  canOpen: boolean;
}

/**
 * 数据管理工作台（基于 `AppNavigationShell` 原生 `HdsNavigation` + 受控 `StableSegmentButton` + 轻通透文件表格）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct DataWorkspace {
  @Prop compact: boolean = false;
  @Prop tabletMode: boolean = false;
  @StorageProp('hongtuReduceMotion') private reduceMotion: boolean = false;
  @StorageProp('collapsedLiveCapsuleInset') private collapsedLiveCapsuleInset: number = 0;
  @StorageProp(RESPONSIVE_HEIGHT_CLASS_KEY) private heightClass: ResponsiveHeightClass = DEFAULT_RESPONSIVE_SNAPSHOT.heightClass;
  @StorageProp(RESPONSIVE_FONT_SCALE_KEY) private fontScale: number = 1;
  @Prop @Watch('syncSelection') files: RecentFile[] = [];
  @Prop @Watch('syncSelection') currentFilePath: string = '';
  @Prop docLibName: string = '';
  @Prop docCellCount: number = 0;
  @Prop docElementCount: number = 0;
  @Prop docTopCellName: string = '';
  @Prop cellTree: CellTreeNode[] = [];
  @Prop currentTopCellId: number = 0;

  openFileAction: () => void = () => {};
  chooseFileAction: (file: RecentFile) => void = () => {};
  showLayoutAction: () => void = () => {};
  enterCellAction: (cellId: number, cellName: string) => void = () => {};
  quickScanAction: () => void = () => {};

  @State private activeTab: DataTab = DataTab.Files;
  @State private searchText: string = '';
  @State private selectedFileKey: string = '';
  @State private pressedRowKey: string = '';
  @State private expandedCellKeys: string[] = [];
  @State private collapsedCellKeys: string[] = [];

  private rowTouchDownX: number = 0;
  private rowTouchDownY: number = 0;
  private lastFileTapKey: string = '';
  private lastFileTapAt: number = 0;
  private lastCellTapKey: string = '';
  private lastCellTapAt: number = 0;

  private filesListScroller: Scroller = new Scroller();
  private cellsListScroller: Scroller = new Scroller();
  private historyListScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.syncSelection();
  }

  private bottomTabAvoidInset(): number {
    if (!this.compact && !this.tabletMode) {
      return 16;
    }
    return getFloatingTabBottomSpacer(this.heightClass, this.fontScale) + this.collapsedLiveCapsuleInset;
  }

  private handleRowTouch(event: TouchEvent, rowKey: string): void {
    const touch: TouchObject | undefined = event.touches.length > 0 ? event.touches[0] :
      (event.changedTouches.length > 0 ? event.changedTouches[0] : undefined);
    if (event.type === TouchType.Down) {
      this.pressedRowKey = rowKey;
      if (touch !== undefined) {
        this.rowTouchDownX = touch.x;
        this.rowTouchDownY = touch.y;
      }
      return;
    }
    if (event.type === TouchType.Move) {
      if (touch !== undefined &&
        Math.hypot(touch.x - this.rowTouchDownX, touch.y - this.rowTouchDownY) > ROW_SCROLL_SLOP_VP &&
        this.pressedRowKey === rowKey) {
        this.pressedRowKey = '';
      }
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.pressedRowKey === rowKey) {
        this.pressedRowKey = '';
      }
    }
  }

  private handleFileRowClick(file: RecentFile): void {
    const key: string = file.key();
    this.selectedFileKey = key;
    const now: number = Date.now();
    const dt: number = now - this.lastFileTapAt;
    if (this.lastFileTapKey === key && dt >= ROW_DOUBLE_TAP_MIN_MS && dt <= ROW_DOUBLE_TAP_MAX_MS) {
      this.lastFileTapKey = '';
      this.lastFileTapAt = 0;
      this.openSelectedFile(file);
      return;
    }
    this.lastFileTapKey = key;
    this.lastFileTapAt = now;
  }

  private handleCellRowClick(node: CellTreeNode): void {
    const key: string = node.key();
    const now: number = Date.now();
    const dt: number = now - this.lastCellTapAt;
    if (this.lastCellTapKey === key && dt >= ROW_DOUBLE_TAP_MIN_MS && dt <= ROW_DOUBLE_TAP_MAX_MS) {
      this.lastCellTapKey = '';
      this.lastCellTapAt = 0;
      this.enterCellAction(node.cellId, node.cellName);
      return;
    }
    this.lastCellTapKey = key;
    this.lastCellTapAt = now;
  }

  private detailCardGeometryId(): string {
    if (this.reduceMotion || this.compact || this.activeTab !== DataTab.Files || this.selectedFileKey.length === 0) {
      return '';
    }
    return ACTIVE_LAYOUT_STAGE_GEOMETRY_ID;
  }

  private buildTabSegmentItems(): SegmentButtonItemTuple {
    const items: [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] = [
      { text: '文件' },
      { text: 'Cell 层级' },
      { text: '导入记录' }
    ];
    return items;
  }

  private buildNavigationMenuItems(): HdsNavigationMenuItemOptions[] {
    return [
      {
        content: {
          label: '快速扫描',
          icon: $r('sys.symbol.magnifyingglass'),
          type: IconStyleMode.SMALL,
          isEnabled: true,
          action: () => { this.quickScanAction(); }
        }
      },
      {
        content: {
          label: '打开文件',
          icon: $r('sys.symbol.folder'),
          type: IconStyleMode.SMALL,
          isEnabled: true,
          action: () => { this.openFileAction(); }
        }
      }
    ];
  }

  private isCurrentFile(file: RecentFile): boolean {
    return this.currentFilePath.length > 0 &&
      (file.sandboxPath === this.currentFilePath || file.sourceUri === this.currentFilePath);
  }

  private fileTopCell(file: RecentFile): string {
    if (this.isCurrentFile(file) && this.docTopCellName.length > 0) {
      return this.docTopCellName;
    }
    const meta: RecentFileSummaryMeta | undefined = resolveRecentFileMetadata(file);
    const resolved: string = file.topCellName ?? meta?.topCellName ?? '';
    return resolved.length > 0 ? resolved : '—';
  }

  private fileCellCount(file: RecentFile): string {
    if (this.isCurrentFile(file)) {
      return this.docCellCount.toString();
    }
    const meta: RecentFileSummaryMeta | undefined = resolveRecentFileMetadata(file);
    const count: number | undefined = file.cellCount ?? meta?.cellCount;
    return count !== undefined && count >= 0 ? count.toString() : '—';
  }

  private fileElementCountText(file: RecentFile): string {
    if (this.isCurrentFile(file)) {
      return `图元 ${this.docElementCount} · ${this.docLibName || '未命名库'}`;
    }
    const meta: RecentFileSummaryMeta | undefined = resolveRecentFileMetadata(file);
    const count: number | undefined = file.elementCount ?? meta?.elementCount;
    return count !== undefined && count >= 0 ? `图元 ${count}` : '';
  }

  private syncSelection(): void {
    if (this.files.some((file: RecentFile): boolean => file.key() === this.selectedFileKey)) {
      return;
    }
    const current: RecentFile | undefined = this.files.find((file: RecentFile): boolean => this.isCurrentFile(file));
    this.selectedFileKey = current !== undefined ? current.key() : (this.files.length > 0 ? this.files[0].key() : '');
  }

  private selectedFile(): RecentFile {
    for (let i = 0; i < this.files.length; i++) {
      if (this.files[i].key() === this.selectedFileKey) {
        return this.files[i];
      }
    }
    return new RecentFile('', '', '');
  }

  private fileRenderKey(file: RecentFile): string {
    const meta: RecentFileSummaryMeta | undefined = resolveRecentFileMetadata(file);
    return JSON.stringify([
      file.key(),
      file.name,
      file.fileType,
      file.fileSizeLabel,
      file.sourceUri,
      file.sandboxPath,
      file.openedAt.toString(),
      file.topCellName ?? meta?.topCellName ?? '',
      (file.cellCount ?? meta?.cellCount ?? -1).toString()
    ]);
  }

  private selectedFileMetric(metric: FileDetailMetric): string {
    const file: RecentFile = this.selectedFile();
    switch (metric) {
      case FileDetailMetric.Format:
        return file.fileType || '—';
      case FileDetailMetric.TopCell:
        return this.fileTopCell(file);
      case FileDetailMetric.CellCount:
        return this.fileCellCount(file);
      case FileDetailMetric.FileSize:
        return file.fileSizeLabel || '—';
      default:
        return '—';
    }
  }

  private filteredFiles(): RecentFile[] {
    const query: string = this.searchText.trim().toLowerCase();
    if (query.length === 0) {
      return this.files;
    }
    return this.files.filter((file: RecentFile): boolean => {
      const topCell: string = this.fileTopCell(file);
      return `${file.name} ${file.fileType} ${file.sourceUri} ${file.sandboxPath} ${topCell}`
        .toLowerCase().includes(query);
    });
  }

  private dateLabel(openedAt: number): string {
    if (openedAt <= 0) {
      return '—';
    }
    const date: Date = new Date(openedAt);
    const month: string = (date.getMonth() + 1).toString().padStart(2, '0');
    const day: string = date.getDate().toString().padStart(2, '0');
    const hours: string = date.getHours().toString().padStart(2, '0');
    const minutes: string = date.getMinutes().toString().padStart(2, '0');
    return `${date.getFullYear()}-${month}-${day} ${hours}:${minutes}`;
  }

  private pathLabel(file: RecentFile): string {
    return file.sourceUri.length > 0 ? file.sourceUri : (file.sandboxPath.length > 0 ? file.sandboxPath : '路径未记录');
  }

  private fileNameFromPath(): string {
    const parts: string[] = this.currentFilePath.replace(/\\/g, '/').split('/');
    return parts.length > 0 ? parts[parts.length - 1] : this.currentFilePath;
  }

  private openSelectedFile(file: RecentFile): void {
    if (this.isCurrentFile(file)) {
      this.showLayoutAction();
    } else {
      this.chooseFileAction(file);
    }
  }

  private isCellExpanded(node: CellTreeNode): boolean {
    if (this.collapsedCellKeys.indexOf(node.key()) >= 0) {
      return false;
    }
    return node.expanded || this.expandedCellKeys.indexOf(node.key()) >= 0;
  }

  private toggleCell(node: CellTreeNode): void {
    const key: string = node.key();
    if (this.isCellExpanded(node)) {
      this.expandedCellKeys = this.expandedCellKeys.filter((item: string): boolean => item !== key);
      this.collapsedCellKeys = [...this.collapsedCellKeys, key];
    } else {
      this.collapsedCellKeys = this.collapsedCellKeys.filter((item: string): boolean => item !== key);
      this.expandedCellKeys = [...this.expandedCellKeys, key];
    }
  }

  private appendVisibleCells(nodes: CellTreeNode[], result: CellTreeNode[], query: string): void {
    for (let i = 0; i < nodes.length; i++) {
      const node: CellTreeNode = nodes[i];
      if (query.length === 0 || node.cellName.toLowerCase().includes(query)) {
        result.push(node);
      }
      if (query.length > 0 || this.isCellExpanded(node)) {
        this.appendVisibleCells(node.children, result, query);
      }
    }
  }

  private visibleCells(): CellTreeNode[] {
    const result: CellTreeNode[] = [];
    this.appendVisibleCells(this.cellTree, result, this.searchText.trim().toLowerCase());
    return result;
  }

  @Builder
  private emptyState(spec: DataEmptyStateSpec) {
    Scroll() {
      Column({ space: 12 }) {
        DataGlyph({ name: this.activeTab === DataTab.Cells ? 'cell' : 'file', iconSize: 28, colorValue: COLORS.muted })
        Text(spec.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLORS.ink)
        if (spec.canOpen) {
          Button('打开文件', { type: ButtonType.Normal })
            .fontSize(13)
            .fontColor(Color.White)
            .backgroundColor(COLORS.primary)
            .height(UI.controlHeight)
            .padding({ left: 20, right: 20 })
            .borderRadius(UI.controlRadius)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .onClick(() => this.openFileAction())
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding(this.compact ? 16 : 28)
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .clipContent(ContentClipMode.SAFE_AREA)
  }

  @Builder
  private compactMetric(spec: DataMetricSpec) {
    Row({ space: 6 }) {
      Text(spec.label).fontSize(11).fontColor(COLORS.muted)
      Text(spec.value).fontSize(12).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
    }
  }

  @Builder
  private summaryMetric(spec: DataMetricSpec) {
    Row({ space: 8 }) {
      if (spec.iconName !== undefined && spec.iconName.length > 0) {
        DataGlyph({ name: spec.iconName, iconSize: 16, colorValue: COLORS.primary })
      }
      Text(`${spec.label} ${spec.value}`).fontSize(12).fontColor(COLORS.muted)
    }
  }

  @Builder
  private fileHeader() {
    Row() {
      if (this.compact) {
        Text('文件名').fontSize(12).fontColor(COLORS.muted).width('42%')
        Text('顶层 Cell').fontSize(12).fontColor(COLORS.muted).width('20%')
        Text('大小').fontSize(12).fontColor(COLORS.muted).width('18%')
        Text('操作').fontSize(12).fontColor(COLORS.muted).width('20%')
      } else {
        Text('文件名').fontSize(12).fontColor(COLORS.muted).width('29%')
        Text('格式').fontSize(12).fontColor(COLORS.muted).width('12%')
        Text('顶层 Cell').fontSize(12).fontColor(COLORS.muted).width('15%')
        Text('Cell 数量').fontSize(12).fontColor(COLORS.muted).width('12%')
        Text('大小').fontSize(12).fontColor(COLORS.muted).width('13%')
        Text('最近打开').fontSize(12).fontColor(COLORS.muted).width('19%')
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: 16, right: 16 })
    .backgroundColor(COLORS.surfaceMuted)
    .border({ width: { bottom: 1 }, color: COLORS.border })
  }

  @Builder
  private fileRow(file: RecentFile) {
    Row() {
      Row({ space: 10 }) {
        DataGlyph({ name: 'file', iconSize: 18, colorValue: COLORS.primary })
        Column({ space: 2 }) {
          Text(file.name)
            .fontSize(13)
            .fontWeight(this.isCurrentFile(file) ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(COLORS.ink)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.isCurrentFile(file)) {
            Text('当前版图').fontSize(10).fontColor(COLORS.primary)
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width(this.compact ? '42%' : '29%').padding({ right: 10 })

      if (!this.compact) {
        Text(file.fileType || '—').fontSize(12).fontColor(COLORS.ink).width('12%')
        Text(this.fileTopCell(file))
          .fontSize(12)
          .fontColor(COLORS.ink)
          .width('15%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.fileCellCount(file)).fontSize(12).fontColor(COLORS.ink).width('12%')
        Text(file.fileSizeLabel || '—').fontSize(12).fontColor(COLORS.ink).width('13%')
        Text(this.dateLabel(file.openedAt)).fontSize(11).fontColor(COLORS.muted).width('19%')
      } else {
        Text(this.fileTopCell(file))
          .fontSize(11)
          .fontColor(COLORS.muted)
          .width('20%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(file.fileSizeLabel || '—').fontSize(12).fontColor(COLORS.ink).width('18%')
        Button(this.isCurrentFile(file) ? '进入' : '打开', { type: ButtonType.Normal })
          .fontSize(12)
          .fontColor(COLORS.primary)
          .backgroundColor(COLORS.primarySoft)
          .width('20%')
          .height(UI.compactControlHeight)
          .borderRadius(UI.controlRadius)
          .onClick(() => this.openSelectedFile(file))
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 16 })
    .animation(null)
    .backgroundColor(file.key() === this.selectedFileKey
      ? COLORS.primarySoft
      : (this.pressedRowKey === `file:${file.key()}` ? COLORS.surfaceMuted : Color.Transparent))
    .scale({
      x: this.pressedRowKey === `file:${file.key()}` ? AnimPress.rowScale : 1,
      y: this.pressedRowKey === `file:${file.key()}` ? AnimPress.rowScale : 1
    })
    .animation({ duration: this.reduceMotion ? 0 : MOTION.feedback, curve: feedbackCurve() })
    .border({ width: { bottom: 0.7 }, color: COLORS.border })
    .onTouch((event: TouchEvent) => this.handleRowTouch(event, `file:${file.key()}`))
    .onClick(() => this.handleFileRowClick(file))
  }

  @Builder
  private fileDetails() {
    Row({ space: 16 }) {
      Column() {
        DataGlyph({ name: 'file', iconSize: 26, colorValue: COLORS.primary })
      }
      .width(44)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(COLORS.primarySoft)
      .borderRadius(10)

      Column({ space: 5 }) {
        Row({ space: 10 }) {
          Text(this.selectedFile().name)
            .fontSize(14)
            .fontColor(COLORS.ink)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.fileElementCountText(this.selectedFile()).length > 0) {
            Text(this.fileElementCountText(this.selectedFile()))
              .fontSize(11)
              .fontColor(COLORS.muted)
              .maxLines(1)
          }
        }.alignItems(VerticalAlign.Center)

        Row({ space: 16 }) {
          this.compactMetric({ label: '格式', value: this.selectedFileMetric(FileDetailMetric.Format) })
          this.compactMetric({ label: '顶层 Cell', value: this.selectedFileMetric(FileDetailMetric.TopCell) })
          this.compactMetric({ label: 'Cell 数量', value: this.selectedFileMetric(FileDetailMetric.CellCount) })
          this.compactMetric({ label: '大小', value: this.selectedFileMetric(FileDetailMetric.FileSize) })
        }.width('100%')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      Button('查看 Cell 层级', { type: ButtonType.Normal })
        .fontSize(12)
        .fontColor(COLORS.ink)
        .height(UI.controlHeight)
        .padding({ left: 16, right: 16 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .enabled(this.isCurrentFile(this.selectedFile()))
        .opacity(this.isCurrentFile(this.selectedFile()) ? 1 : 0.45)
        .onClick(() => {
          this.activeTab = DataTab.Cells;
          this.searchText = '';
        })

      if (this.isCurrentFile(this.selectedFile())) {
        Button('进入版图', { type: ButtonType.Normal })
          .fontSize(12)
          .fontColor(Color.White)
          .height(UI.controlHeight)
          .padding({ left: 18, right: 18 })
          .backgroundColor(COLORS.primary)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.showLayoutAction())
      } else {
        Button('打开版图', { type: ButtonType.Normal })
          .fontSize(12)
          .fontColor(Color.White)
          .height(UI.controlHeight)
          .padding({ left: 18, right: 18 })
          .backgroundColor(COLORS.primary)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.chooseFileAction(this.selectedFile()))
      }
    }
    .width('100%')
    .padding(16)
    .border({ width: { top: 0.8 }, color: COLORS.border })
    .geometryTransition(this.detailCardGeometryId(), { follow: false })
  }

  @Builder
  private filesPage() {
    Column() {
      if (!this.compact || this.files.length > 0) {
        this.fileHeader()
      }
      if (this.files.length === 0) {
        this.emptyState({
          title: this.activeTab === DataTab.History ? '暂无导入记录' : '暂无版图文件',
          canOpen: true
        })
      } else if (this.filteredFiles().length === 0) {
        this.emptyState({ title: '没有匹配的文件', canOpen: false })
      } else {
        List({ scroller: this.filesListScroller }) {
          ForEach(this.filteredFiles(), (file: RecentFile) => {
            ListItem() { this.fileRow(file) }
          }, (file: RecentFile): string => this.fileRenderKey(file))
          ListItem() { Row().width('100%').height(this.bottomTabAvoidInset()) }
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(10)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clipContent(ContentClipMode.SAFE_AREA)
      }
      if (!this.compact && this.selectedFileKey.length > 0 && this.filteredFiles().length > 0) {
        this.fileDetails()
      }
    }
    .width('100%')
    .layoutWeight(1)
    .attributeModifier(hongTuThemeState.luminousCardModifier(UI.panelRadius))
  }

  @Builder
  private cellRow(node: CellTreeNode) {
    Row() {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({
            name: node.children.length > 0 ? (this.isCellExpanded(node) ? 'chevronDown' : 'chevronRight') : 'cell',
            iconSize: 14,
            color: node.children.length > 0 ? COLORS.primary : COLORS.muted
          })
        }
        .width(UI.compactControlHeight)
        .height(UI.compactControlHeight)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(UI.controlRadius)
        .enabled(node.children.length > 0)
        .accessibilityText(this.isCellExpanded(node) ? '折叠 Cell 层级' : '展开 Cell 层级')
        .onClick(() => {
          if (node.children.length > 0) {
            this.toggleCell(node);
          }
        })
        DataGlyph({ name: 'cell', iconSize: 18, colorValue: COLORS.primary })
        Text(node.cellName)
          .fontSize(13)
          .fontColor(node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.ink)
          .fontWeight(node.cellId === this.currentTopCellId ? FontWeight.Medium : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('52%')
      .padding({ left: Math.min(node.depth * 20, 120), right: 16 })

      Text(node.cellId === this.currentTopCellId ? '当前顶层' : 'Cell')
        .fontSize(12)
        .fontColor(node.cellId === this.currentTopCellId ? COLORS.primary : COLORS.muted)
        .width('16%')
      Text(node.referenceCount.toString()).fontSize(12).fontColor(COLORS.ink).width('16%')
      Button('进入版图', { type: ButtonType.Normal })
        .fontSize(12)
        .fontColor(COLORS.primary)
        .backgroundColor(Color.Transparent)
        .height(UI.compactControlHeight)
        .width('16%')
        .borderRadius(UI.controlRadius)
        .onClick(() => this.enterCellAction(node.cellId, node.cellName))
    }
    .height(48)
    .width('100%')
    .padding({ left: 16, right: 16 })
    .animation(null)
    .backgroundColor(node.cellId === this.currentTopCellId
      ? COLORS.primarySoft
      : (this.pressedRowKey === `cell:${node.key()}` ? COLORS.surfaceMuted : Color.Transparent))
    .scale({
      x: this.pressedRowKey === `cell:${node.key()}` ? AnimPress.rowScale : 1,
      y: this.pressedRowKey === `cell:${node.key()}` ? AnimPress.rowScale : 1
    })
    .animation({ duration: this.reduceMotion ? 0 : MOTION.feedback, curve: feedbackCurve() })
    .border({ width: { bottom: 0.7 }, color: COLORS.border })
    .onTouch((event: TouchEvent) => this.handleRowTouch(event, `cell:${node.key()}`))
    .onClick(() => this.handleCellRowClick(node))
  }

  @Builder
  private cellsPage() {
    Column() {
      if (this.currentFilePath.length === 0) {
        this.emptyState({ title: '尚未加载版图文件', canOpen: true })
      } else {
        Row() {
          Column({ space: 4 }) {
            Text(this.fileNameFromPath()).fontSize(15).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
            Text(`${this.docLibName || '未命名库'} · ${this.docCellCount} 个 Cell · ${this.docElementCount} 个图元`)
              .fontSize(12)
              .fontColor(COLORS.muted)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Button('返回当前版图', { type: ButtonType.Normal })
            .fontSize(12)
            .fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted)
            .height(UI.controlHeight)
            .padding({ left: 16, right: 16 })
            .borderRadius(UI.controlRadius)
            .onClick(() => this.showLayoutAction())
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .border({ width: { bottom: 0.8 }, color: COLORS.border })

        Row() {
          Text('Cell 名称').fontSize(12).fontColor(COLORS.muted).width('52%')
          Text('状态').fontSize(12).fontColor(COLORS.muted).width('16%')
          Text('引用次数').fontSize(12).fontColor(COLORS.muted).width('16%')
          Text('操作').fontSize(12).fontColor(COLORS.muted).width('16%')
        }
        .height(40)
        .width('100%')
        .padding({ left: 16, right: 16 })
        .backgroundColor(COLORS.surfaceMuted)

        if (this.visibleCells().length === 0) {
          this.emptyState({
            title: this.searchText.length > 0 ? '没有匹配的 Cell' : '暂无 Cell 层级',
            canOpen: false
          })
        } else {
          List({ scroller: this.cellsListScroller }) {
            ForEach(this.visibleCells(), (node: CellTreeNode) => {
              ListItem() {
                this.cellRow(node)
              }
            }, (node: CellTreeNode): string => node.key())
            ListItem() { Row().width('100%').height(this.bottomTabAvoidInset()) }
          }
          .width('100%')
          .layoutWeight(1)
          .cachedCount(10)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .clipContent(ContentClipMode.SAFE_AREA)
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .attributeModifier(hongTuThemeState.luminousCardModifier(UI.panelRadius))
  }

  @Builder
  private historyPage() {
    Column() {
      Row() {
        Text('文件名').fontSize(12).fontColor(COLORS.muted).width('34%')
        Text('顶层 Cell').fontSize(12).fontColor(COLORS.muted).width('14%')
        Text('格式').fontSize(12).fontColor(COLORS.muted).width('10%')
        Text('大小').fontSize(12).fontColor(COLORS.muted).width('12%')
        Text('最近打开').fontSize(12).fontColor(COLORS.muted).width('16%')
        Text('操作').fontSize(12).fontColor(COLORS.muted).width('14%')
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: { bottom: 1 }, color: COLORS.border })

      if (this.filteredFiles().length === 0) {
        this.emptyState({
          title: this.files.length === 0 ? '暂无导入记录' : '没有匹配的记录',
          canOpen: this.files.length === 0
        })
      } else {
        List({ scroller: this.historyListScroller }) {
          ForEach(this.filteredFiles(), (file: RecentFile) => {
            ListItem() {
              Row() {
                Row({ space: 10 }) {
                  DataGlyph({ name: 'file', iconSize: 18, colorValue: COLORS.muted })
                  Column({ space: 2 }) {
                    Text(file.name)
                      .fontSize(13)
                      .fontColor(COLORS.ink)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.pathLabel(file))
                      .fontSize(10)
                      .fontColor(COLORS.muted)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }.width('34%').padding({ right: 12 })

                Text(this.fileTopCell(file))
                  .fontSize(12)
                  .fontColor(COLORS.ink)
                  .width('14%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(file.fileType || '—').fontSize(12).fontColor(COLORS.ink).width('10%')
                Text(file.fileSizeLabel || '—').fontSize(12).fontColor(COLORS.ink).width('12%')
                Text(file.openedAt > 0 ? this.dateLabel(file.openedAt) : '—')
                  .fontSize(11)
                  .fontColor(COLORS.muted)
                  .width('16%')
                Button(this.isCurrentFile(file) ? '进入版图' : '重新打开', { type: ButtonType.Normal })
                  .fontSize(12)
                  .fontColor(COLORS.primary)
                  .backgroundColor(Color.Transparent)
                  .width('14%')
                  .height(UI.compactControlHeight)
                  .borderRadius(UI.controlRadius)
                  .onClick(() => this.openSelectedFile(file))
              }
              .width('100%')
              .height(48)
              .padding({ left: 16, right: 16 })
              .border({ width: { bottom: 0.7 }, color: COLORS.border })
            }
          }, (file: RecentFile): string => this.fileRenderKey(file))
          ListItem() { Row().width('100%').height(this.bottomTabAvoidInset()) }
        }
        .width('100%')
        .layoutWeight(1)
        .cachedCount(10)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clipContent(ContentClipMode.SAFE_AREA)
      }
    }
    .width('100%')
    .layoutWeight(1)
    .attributeModifier(hongTuThemeState.luminousCardModifier(UI.panelRadius))
  }

  @Builder
  private buildNavBottomSwitcher() {
    Row() {
      StableSegmentButton({
        items: this.buildTabSegmentItems(),
        selectedIndex: this.activeTab as number,
        onItemClicked: (index: number) => {
          this.activeTab = index as DataTab;
          this.searchText = '';
        },
        inNavigationBar: true,
        fontColor: COLORS.muted,
        selectedFontColor: COLORS.primary,
        capsuleBackgroundColor: COLORS.surfaceMuted,
        selectedBackgroundColor: COLORS.primarySoft,
        fontSizeFp: 13,
        capsuleBorderRadius: 12,
        buttonMinHeight: 38,
        itemMinHeight: 32
      })
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 16, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private compactSearch() {
    Search({ value: this.searchText, placeholder: this.activeTab === DataTab.Cells ? '搜索 Cell 名称' : '搜索文件名、顶层 Cell 或格式' })
      .height(UI.fieldHeight)
      .width('100%')
      .textFont({ size: UI.fontBody })
      .placeholderFont({ size: UI.fontBody })
      .fontColor(COLORS.ink)
      .placeholderColor(COLORS.muted)
      .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
        ? hongTuThemeState.luminous.translucentCardColor
        : COLORS.surface)
      .border({ width: 0.8, color: COLORS.border })
      .borderRadius(UI.controlRadius)
      .onKeyEvent((event: KeyEvent) => event.stopPropagation())
      .onChange((value: string) => { this.searchText = value; })
  }

  @Builder
  private compactBody() {
    Column({ space: 10 }) {
      this.compactSearch()

      if (this.activeTab === DataTab.Cells) {
        this.cellsPage()
      } else if (this.activeTab === DataTab.History) {
        this.historyPage()
      } else {
        this.filesPage()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    if (this.compact) {
      AppNavigationShell({
        title: '数据管理',
        subTitle: '',
        largeTitle: false,
        showBottomContent: true,
        bottomContentHeight: 48,
        menuItems: this.buildNavigationMenuItems(),
        scrollables: [this.filesListScroller, this.cellsListScroller, this.historyListScroller],
        bottomContent: (): void => { this.buildNavBottomSwitcher(); }
      }) {
        this.compactBody()
      }
    } else {
      Column() {
        Row({ space: 12 }) {
          Text('数据管理')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLORS.ink)
          if (this.files.length > 0) {
            this.summaryMetric({ label: '最近文件', value: `${this.files.length}`, iconName: 'file' })
          }
          Blank()
          Button({ type: ButtonType.Normal }) {
            Row({ space: 8 }) {
              DataGlyph({ name: 'scan', iconSize: 18, colorValue: COLORS.ink })
              Text('快速扫描').fontSize(UI.fontBody).fontColor(COLORS.ink)
            }
          }
          .height(UI.controlHeight)
          .padding({ left: 18, right: 18 })
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.quickScanAction())

          Button({ type: ButtonType.Normal }) {
            Row({ space: 8 }) {
              WorkbenchIcon({ name: 'open', iconSize: 18, color: '#FFFFFF' })
              Text('打开文件').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(Color.White)
            }
          }
          .height(UI.controlHeight)
          .padding({ left: 20, right: 20 })
          .backgroundColor(COLORS.primary)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.openFileAction())
        }
        .width('100%')
        .margin({ bottom: 14 })
        .alignItems(VerticalAlign.Center)

        Row({ space: 16 }) {
          Row() {
            StableSegmentButton({
              items: this.buildTabSegmentItems(),
              selectedIndex: this.activeTab as number,
              onItemClicked: (index: number) => {
                this.activeTab = index as DataTab;
                this.searchText = '';
              },
              fontColor: COLORS.muted,
              selectedFontColor: COLORS.primary,
              capsuleBackgroundColor: COLORS.surfaceMuted,
              selectedBackgroundColor: COLORS.primarySoft,
              fontSizeFp: 13,
              capsuleBorderRadius: 10,
              buttonMinHeight: 36,
              itemMinHeight: 30
            })
          }
          .width(310)

          Blank()

          Search({ value: this.searchText, placeholder: this.activeTab === DataTab.Cells ? '搜索 Cell 名称' : '搜索文件名、顶层 Cell 或格式' })
            .height(UI.controlHeight)
            .width('34%')
            .constraintSize({ maxWidth: 360 })
            .textFont({ size: UI.fontBody })
            .placeholderFont({ size: UI.fontBody })
            .fontColor(COLORS.ink)
            .placeholderColor(COLORS.muted)
            .searchIcon({ size: 18, color: COLORS.muted })
            .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 16, color: COLORS.muted } })
            .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
              ? hongTuThemeState.luminous.translucentCardColor
              : COLORS.surface)
            .border({ width: 0.8, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .onKeyEvent((event: KeyEvent) => event.stopPropagation())
            .onChange((value: string) => {
              this.searchText = value;
              const visible: RecentFile[] = this.filteredFiles();
              if (!visible.some((file: RecentFile): boolean => file.key() === this.selectedFileKey) && visible.length > 0) {
                this.selectedFileKey = visible[0].key();
              }
            })
        }
        .width('100%')
        .height(44)
        .margin({ bottom: 10 })

        if (this.activeTab === DataTab.Files) {
          this.filesPage()
        } else if (this.activeTab === DataTab.Cells) {
          this.cellsPage()
        } else {
          this.historyPage()
        }
      }
      .width('100%')
      .height('100%')
      .padding(24)
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(Color.Transparent)
    }
  }
}

@Component
struct DataGlyph {
  @Prop name: string = 'file';
  @Prop iconSize: number = 24;
  @Prop colorValue: string = COLORS.muted;

  private commands(): string {
    switch (this.name) {
      case 'cells': return 'M12 2L22 7L12 12L2 7Z M2 12L12 17L22 12 M2 17L12 22L22 17';
      case 'elements': return 'M12 4L4 20H20Z M14 4A2 2 0 1 1 10 4A2 2 0 1 1 14 4 M6 20A2 2 0 1 1 2 20A2 2 0 1 1 6 20 M22 20A2 2 0 1 1 18 20A2 2 0 1 1 22 20';
      case 'cell': return 'M5 5H19V19H5Z M9 9H15V15H9Z M8 2V5 M12 2V5 M16 2V5 M8 19V22 M12 19V22 M16 19V22 M2 8H5 M2 12H5 M2 16H5 M19 8H22 M19 12H22 M19 16H22';
      case 'scan': return 'M8 3H3V8 M16 3H21V8 M3 16V21H8 M21 16V21H16 M7 12H17';
      default: return 'M6 2H14L20 8V22H6Z M14 2V8H20';
    }
  }

  build() {
    Shape() {
      Path()
        .commands(this.commands())
        .fill(Color.Transparent)
        .stroke(this.colorValue)
        .strokeWidth('1.6px')
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
    }
    .viewPort({ x: '0px', y: '0px', width: '24px', height: '24px' })
    .width(this.iconSize)
    .height(this.iconSize)
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }
}
