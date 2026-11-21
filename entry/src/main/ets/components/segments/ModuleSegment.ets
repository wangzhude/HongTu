import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { UI } from '../../common/UiTokens';
import { COLORS } from '../../common/constants';
import { StableSegmentButton } from '../StableSegmentButton';

/**
 * 模块切换受控分段控件（版图编辑 / 验证检查 / 数据管理）
 *
 * 基于受控 `StableSegmentButton` 封装，消除动态宽度首帧跳变并联动全局光感材质。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct ModuleSegment {
  @Prop paletteKey: string = '';
  @Prop current: number = 0;
  @Prop drcBadge: number = 0;
  @Prop inNavigationBar: boolean = false;
  onChange: (index: number) => void = () => {};

  private buildItems(): SegmentButtonItemTuple {
    const verifyLabel: string = this.drcBadge > 0 ? `验证检查 (${this.drcBadge})` : '验证检查';
    const items: [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] = [
      { text: '版图编辑' },
      { text: verifyLabel },
      { text: '数据管理' }
    ];
    return items;
  }

  build() {
    StableSegmentButton({
      items: this.buildItems(),
      selectedIndex: this.current,
      onItemClicked: (index: number) => {
        if (index !== this.current) {
          this.onChange(index);
        }
      },
      fontColor: COLORS.muted,
      selectedFontColor: COLORS.primary,
      capsuleBackgroundColor: COLORS.surfaceMuted,
      selectedBackgroundColor: COLORS.primarySoft,
      inNavigationBar: this.inNavigationBar,
      fontSizeFp: UI.fontCaption,
      capsuleBorderRadius: UI.controlRadius,
      itemPaddingHorizontal: 8,
      itemPaddingVertical: 5,
      buttonMinHeight: 34,
      itemMinHeight: 28
    })
  }
}
