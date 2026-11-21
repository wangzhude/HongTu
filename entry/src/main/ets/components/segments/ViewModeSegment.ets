import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { UI } from '../../common/UiTokens';
import { COLORS } from '../../common/constants';
import { StableSegmentButton } from '../StableSegmentButton';

/**
 * 视图模式受控分段控件（查看 / 编辑）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct ViewModeSegment {
  @Prop paletteKey: string = '';
  @Prop current: string = '编辑';
  @Prop inNavigationBar: boolean = false;
  onChange: (mode: string) => void = () => {};

  private buildItems(): SegmentButtonItemTuple {
    const items: [SegmentButtonTextItem, SegmentButtonTextItem] = [
      { text: '查看' },
      { text: '编辑' }
    ];
    return items;
  }

  build() {
    StableSegmentButton({
      items: this.buildItems(),
      selectedIndex: this.current === '查看' ? 0 : 1,
      onItemClicked: (index: number) => {
        const nextMode: string = index === 0 ? '查看' : '编辑';
        if (nextMode !== this.current) {
          this.onChange(nextMode);
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
