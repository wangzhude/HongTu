/**
 * 受控原生胶囊分段器（`StableSegmentButton`）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 1. 基于 V1 `SegmentButton` 封装，避开 HarmonyOS 6.1+ V2 测量路径偶发稀疏 `itemRects`；
 * 2. 通过 `postFrameCallback` 在空闲帧受控对齐外部 `selectedIndex`，并去重点击与双向绑定信号，
 *    支持键盘方向键与鼠标滚轮切换；
 * 3. 与全局光感材质自动联动：在 `HdsNavigation` 顶栏内支持挂载 `uiMaterial.ImmersiveStyle.THIN` 官材，
 *    普通内容区联动 `floatingGlassColor` + 档位模糊或轻通透面板色。
 */

import {
  BorderRadiusMode,
  FrameCallback,
  LengthMetrics,
  SegmentButton,
  SegmentButtonItemTuple,
  SegmentButtonOptions,
  uiMaterial
} from '@kit.ArkUI';
import { buildSystemImmersiveMaterial, hongTuThemeState } from '../store/ThemeStore';
import { resolveFallbackBlurStyleForPreset } from '../store/LuminousSurfaceOptions';

class SegmentSelectionFrameCallback extends FrameCallback {
  private readonly reconcile: () => void;

  constructor(reconcile: () => void) {
    super();
    this.reconcile = reconcile;
  }

  onIdle(_timeLeftInNano: number): void {
    this.reconcile();
  }
}

@Component
export struct StableSegmentButton {
  @Prop @Watch('refreshOptions') items: SegmentButtonItemTuple = [{ text: '' }, { text: '' }];
  @Prop @Watch('syncControlledSelection') selectedIndex: number = 0;
  onItemClicked: (index: number) => void = () => {};

  @Prop @Watch('refreshOptions') fontColor: ResourceColor = $r('sys.color.font_secondary');
  @Prop @Watch('refreshOptions') selectedFontColor: ResourceColor = '#FFFFFF';
  @Prop @Watch('refreshOptions') selectedBackgroundColor: ResourceColor = $r('sys.color.comp_background_emphasize');
  @Prop @Watch('refreshOptions') capsuleBackgroundColor: ResourceColor = $r('sys.color.comp_background_tertiary');
  @Prop @Watch('refreshOptions') capsuleBlurStyle?: BlurStyle = undefined;
  @Prop @Watch('refreshOptions') backgroundSystemMaterial?: uiMaterial.Material = undefined;
  @Prop @Watch('refreshOptions') inNavigationBar: boolean = false;
  @Prop @Watch('refreshOptions') fontSizeFp: number = 12;
  @Prop itemMinHeight: number = 30;
  @Prop buttonMinHeight: number = 34;
  @Prop buttonPadding: number = 2;
  @Prop @Watch('refreshOptions') itemPaddingVertical: number = 5;
  @Prop @Watch('refreshOptions') itemPaddingHorizontal: number = 8;
  @Prop maxFontScale: number = 1.4;
  @Prop @Watch('refreshOptions') capsuleBorderRadius: number = 10;
  @Prop enableStateAnimation: boolean = true;

  @State private options: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [{ text: '' }, { text: '' }]
  });
  @State @Watch('onNativeSelectionChanged') private nativeSelectedIndexes: number[] = [0];
  @State private initialized: boolean = false;
  private synchronizingSelection: boolean = false;
  private appeared: boolean = false;
  private pendingTapIndex: number = -1;
  private tapGeneration: number = 0;
  private reconcileGeneration: number = 0;
  private reconcilePending: boolean = false;

  aboutToAppear(): void {
    this.appeared = true;
    this.refreshOptions();
    this.syncControlledSelection();
    this.initialized = true;
  }

  aboutToDisappear(): void {
    this.appeared = false;
    this.initialized = false;
    this.pendingTapIndex = -1;
    this.tapGeneration++;
    this.reconcileGeneration++;
    this.reconcilePending = false;
  }

  private resolveMaterial(): uiMaterial.Material | undefined {
    if (this.backgroundSystemMaterial !== undefined) {
      return this.backgroundSystemMaterial;
    }
    if (this.inNavigationBar && hongTuThemeState.useSystemImmersiveMaterial()) {
      return buildSystemImmersiveMaterial(uiMaterial.ImmersiveStyle.THIN, false);
    }
    return undefined;
  }

  private refreshOptions(): void {
    const sysMaterial: uiMaterial.Material | undefined = this.resolveMaterial();
    const resolvedBgColor: ResourceColor = sysMaterial !== undefined
      ? Color.Transparent
      : this.capsuleBackgroundColor;
    const resolvedBlur: BlurStyle | undefined = sysMaterial !== undefined
      ? BlurStyle.NONE
      : (this.capsuleBlurStyle !== undefined
        ? this.capsuleBlurStyle
        : (this.inNavigationBar && hongTuThemeState.isLuminousMaterialEnabled()
          ? resolveFallbackBlurStyleForPreset(hongTuThemeState.luminousIntensityPreset)
          : undefined));

    this.options = SegmentButtonOptions.capsule({
      buttons: this.items,
      multiply: false,
      fontSize: this.fontSizeFp,
      selectedFontSize: this.fontSizeFp,
      fontColor: this.fontColor,
      selectedFontColor: this.selectedFontColor,
      selectedBackgroundColor: this.selectedBackgroundColor,
      backgroundColor: resolvedBgColor,
      backgroundBlurStyle: resolvedBlur,
      backgroundSystemMaterial: sysMaterial,
      buttonPadding: {
        top: this.itemPaddingVertical,
        bottom: this.itemPaddingVertical,
        left: this.itemPaddingHorizontal,
        right: this.itemPaddingHorizontal
      },
      borderRadiusMode: BorderRadiusMode.CUSTOM,
      backgroundBorderRadius: LengthMetrics.vp(this.capsuleBorderRadius),
      itemBorderRadius: LengthMetrics.vp(Math.max(6, this.capsuleBorderRadius - 2))
    });
  }

  private isValidIndex(index: number): boolean {
    return Number.isInteger(index) && index >= 0 && index < this.items.length;
  }

  private syncControlledSelection(): void {
    const index: number = this.isValidIndex(this.selectedIndex) ? this.selectedIndex : -1;
    if ((index === -1 && this.nativeSelectedIndexes.length === 0) ||
      (this.nativeSelectedIndexes.length === 1 && this.nativeSelectedIndexes[0] === index)) {
      return;
    }
    this.synchronizingSelection = true;
    this.nativeSelectedIndexes = index === -1 ? [] : [index];
    this.synchronizingSelection = false;
  }

  private handleNativeClick(index: number): void {
    if (!this.appeared || !this.isValidIndex(index)) {
      return;
    }
    this.pendingTapIndex = index;
    const generation: number = ++this.tapGeneration;
    this.onItemClicked(index);
    Promise.resolve().then((): void => {
      if (this.tapGeneration === generation) {
        this.pendingTapIndex = -1;
      }
    });
    this.scheduleControlledReconciliation();
  }

  private onNativeSelectionChanged(): void {
    if (!this.appeared || this.synchronizingSelection) {
      return;
    }
    const index: number = this.nativeSelectedIndexes[0];
    if (this.isValidIndex(index) && index !== this.pendingTapIndex) {
      this.onItemClicked(index);
    }
    this.scheduleControlledReconciliation();
  }

  private scheduleControlledReconciliation(): void {
    if (!this.appeared || this.reconcilePending) {
      return;
    }
    this.reconcilePending = true;
    const generation: number = ++this.reconcileGeneration;
    this.getUIContext().postFrameCallback(new SegmentSelectionFrameCallback((): void => {
      if (!this.appeared || generation !== this.reconcileGeneration) {
        return;
      }
      this.reconcilePending = false;
      this.syncControlledSelection();
    }));
  }

  build() {
    Row() {
      if (this.initialized && this.items.length >= 2) {
        SegmentButton({
          options: this.options,
          selectedIndexes: $nativeSelectedIndexes,
          onItemClicked: (index: number): void => { this.handleNativeClick(index); },
          maxFontScale: this.maxFontScale,
          enableStateAnimation: this.enableStateAnimation
        })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: Math.max(this.buttonMinHeight, this.itemMinHeight + this.buttonPadding * 2) })
  }
}
