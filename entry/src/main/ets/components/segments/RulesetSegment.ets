import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { UI } from '../../common/UiTokens';
import { COLORS } from '../../common/constants';
import { StableSegmentButton } from '../StableSegmentButton';

/**
 * 规则集受控分段控件（28nm默认 / 14nm默认 / 7nm默认 / SKY130 M1子集 / 自定义）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
const RULESET_NAMES: string[] = ['28nm默认', '14nm默认', '7nm默认', 'SKY130 M1子集', '自定义'];

@Component
export struct RulesetSegment {
  @Prop paletteKey: string = '';
  @Prop current: number = 0;
  onChange: (index: number) => void = () => {};

  private buildItems(): SegmentButtonItemTuple {
    const items: [
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem
    ] = [
      { text: RULESET_NAMES[0] },
      { text: RULESET_NAMES[1] },
      { text: RULESET_NAMES[2] },
      { text: RULESET_NAMES[3] },
      { text: RULESET_NAMES[4] }
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
      fontSizeFp: UI.fontCaption,
      capsuleBorderRadius: UI.controlRadius,
      itemPaddingHorizontal: 6,
      itemPaddingVertical: 5,
      buttonMinHeight: 32,
      itemMinHeight: 28
    })
  }
}
