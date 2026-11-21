import { ItemRestriction, SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { UI } from '../../common/UiTokens';
import { COLORS } from '../../common/constants';
import { StableSegmentButton } from '../StableSegmentButton';

/** Native controlled selection, keyboard navigation and sliding indicator for workbench filters. */
@Component
export struct WorkbenchSegment {
  @Prop paletteKey: string = '';
  @Prop current: number = 0;
  @Prop labels: string[] = ['查看', '编辑'];
  @Prop inNavigationBar: boolean = false;
  onChange: (index: number) => void = () => {};

  private buildItems(): SegmentButtonItemTuple {
    const buttons: ItemRestriction<SegmentButtonTextItem> = [
      { text: this.labels[0] ?? '' },
      { text: this.labels[1] ?? '' }
    ];
    for (let index: number = 2; index < Math.min(5, this.labels.length); index++) {
      buttons.push({ text: this.labels[index] });
    }
    return buttons as SegmentButtonItemTuple;
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
      buttonMinHeight: 32,
      itemMinHeight: 28
    })
  }
}
