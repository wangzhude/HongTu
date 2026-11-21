import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { WorkspaceTab } from '../../services/WorkspaceService';
import { NextFrameCallback } from '../../store/AnimationTokens';
import { hongTuThemeState } from '../../store/ThemeStore';
import { DrawnStatusIcon } from '../DrawnStatusIcon';
import { WorkbenchIcon } from './WorkbenchIcon';

interface WorkspaceTabBounds {
  key: string;
  left: number;
  width: number;
}

@Component
struct WorkspaceTabItem {
  @Prop tabId: string = '';
  @Prop title: string = '';
  @Prop dirty: boolean = false;
  @Prop isActive: boolean = false;
  onSelect: () => void = () => {};
  onClose: () => void = () => {};
  onMeasured: (area: Area) => void = () => {};

  build() {
    Row({ space: 4 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 5 }) {
          Text(this.title)
            .fontSize(12)
            .fontWeight(this.isActive ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.isActive ? COLORS.primary : COLORS.muted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 196 })
          if (this.dirty) {
            DrawnStatusIcon({ kind: 'dirty', iconSize: 8, strokeColor: COLORS.warning, showSoftPlate: false })
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(34)
      .padding({ left: 12, right: 6 })
      .backgroundColor(Color.Transparent)
      .borderRadius(UI.controlRadius)
      .accessibilityText(`切换到 ${this.title}`)
      .accessibilitySelected(this.isActive)
      .onClick(() => this.onSelect())

      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({ name: 'close', iconSize: 12, color: COLORS.muted })
      }
      .width(26)
      .height(26)
      .padding(0)
      .margin({ right: 6 })
      .backgroundColor(Color.Transparent)
      .borderRadius(UI.controlRadius)
      .hoverEffect(HoverEffect.Highlight)
      .accessibilityText(`关闭 ${this.title}`)
      .onClick(() => this.onClose())
    }
    .height(38)
    .backgroundColor(this.isActive ? COLORS.surface : Color.Transparent)
    .border({ width: { bottom: this.isActive ? 2 : 0 }, color: COLORS.primary })
    .onAreaChange((_oldArea: Area, newArea: Area) => this.onMeasured(newArea))
  }
}

@Component
export struct WorkspaceTabs {
  @Prop @Watch('onTabsChanged') tabs: WorkspaceTab[] = [];
  @Prop @Watch('requestActiveReveal') activeId: string = '';
  @Prop desktopMode: boolean = false;
  selectAction: (id: string) => void = () => {};
  closeAction: (id: string) => void = () => {};
  newAction: () => void = () => {};
  private tabsScroller: Scroller = new Scroller();
  private viewportWidth: number = 0;
  private activeBounds: WorkspaceTabBounds | null = null;
  private pendingRevealId: string = '';
  private revealGeneration: number = 0;
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    this.requestActiveReveal();
  }

  aboutToDisappear(): void {
    this.alive = false;
    this.revealGeneration++;
    this.pendingRevealId = '';
    this.activeBounds = null;
    this.viewportWidth = 0;
  }

  private onTabsChanged(): void {
    if (this.pendingRevealId !== '') this.queueActiveReveal();
  }

  private requestActiveReveal(): void {
    this.revealGeneration++;
    this.pendingRevealId = this.activeId;
    this.queueActiveReveal();
  }

  private queueActiveReveal(): void {
    if (!this.alive || this.pendingRevealId === '') return;
    const generation: number = this.revealGeneration;
    const id: string = this.pendingRevealId;
    this.getUIContext().postFrameCallback(new NextFrameCallback(() => {
      if (!this.alive || generation !== this.revealGeneration || id !== this.activeId ||
        id !== this.pendingRevealId) return;
      const tab: WorkspaceTab | undefined = this.tabs.find((item: WorkspaceTab) => item.id === id);
      const bounds: WorkspaceTabBounds | null = this.activeBounds;
      if (tab === undefined || bounds === null || this.viewportWidth <= 0 ||
        bounds.key !== `${tab.id}:${tab.title}:${tab.dirty}`) return;
      const offset: OffsetResult = this.tabsScroller.currentOffset();
      if (offset === undefined || !Number.isFinite(offset.xOffset)) return;
      let target: number = offset.xOffset;
      if (bounds.width > this.viewportWidth || bounds.left < target) target = bounds.left;
      else if (bounds.left + bounds.width > target + this.viewportWidth) {
        target = bounds.left + bounds.width - this.viewportWidth;
      }
      this.pendingRevealId = '';
      if (target !== offset.xOffset) {
        this.tabsScroller.scrollTo({ xOffset: Math.max(0, target), yOffset: 0, animation: false });
      }
    }));
  }

  private measureTab(tab: WorkspaceTab, area: Area): void {
    if (tab.id !== this.activeId) return;
    const current: WorkspaceTab | undefined = this.tabs.find((item: WorkspaceTab) => item.id === tab.id);
    if (current === undefined || current.title !== tab.title || current.dirty !== tab.dirty) return;
    const left: number = Number(area.position.x);
    const width: number = Number(area.width);
    if (!Number.isFinite(left) || left < 0 || !Number.isFinite(width) || width <= 0) return;
    this.activeBounds = { key: `${tab.id}:${tab.title}:${tab.dirty}`, left: left, width: width };
    if (this.pendingRevealId === tab.id) this.queueActiveReveal();
  }

  private measureViewport(area: Area): void {
    const width: number = Number(area.width);
    if (!Number.isFinite(width) || width <= 0 || width === this.viewportWidth) return;
    this.viewportWidth = width;
    this.requestActiveReveal();
  }

  build() {
    Row() {
      Scroll(this.tabsScroller) {
        Row({ space: 2 }) {
          ForEach(this.tabs, (tab: WorkspaceTab) => {
            WorkspaceTabItem({
              tabId: tab.id,
              title: tab.title,
              dirty: tab.dirty,
              isActive: tab.id === this.activeId,
              onSelect: () => this.selectAction(tab.id),
              onClose: () => this.closeAction(tab.id),
              onMeasured: (area: Area) => this.measureTab(tab, area)
            })
          }, (tab: WorkspaceTab) => tab.id)
          Button({ type: ButtonType.Normal }) {
            WorkbenchIcon({ name: 'plus', iconSize: 16, color: COLORS.muted })
          }
          .width(UI.compactControlHeight).height(UI.compactControlHeight).padding(0)
          .borderRadius(UI.controlRadius).backgroundColor(Color.Transparent)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .accessibilityText('新建版图').bindTips('新建版图').onClick(() => this.newAction())
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .layoutWeight(1)
      .align(Alignment.Start)
      .onAreaChange((_oldArea: Area, newArea: Area) => this.measureViewport(newArea))
    }
    .height(40)
    .padding({ left: this.desktopMode ? UI.railWidth + 6 : 8, right: 12 })
    .width('100%')
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.bg)
    .border({ width: { bottom: 0.8 }, color: COLORS.border })
  }
}
