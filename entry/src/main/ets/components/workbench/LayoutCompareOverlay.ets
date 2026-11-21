import type { NativeLayoutCompareLayer } from '../../../cpp/types/libhongtu/Index';

/** XOR regions are an overlay only: they never become editable layout geometry. */
@Component
export struct LayoutCompareOverlay {
  @Prop differences: NativeLayoutCompareLayer[] = [];
  @Prop scalePxPerNm: number = 1;
  @Prop viewOffsetX: number = 0;
  @Prop viewOffsetY: number = 0;
  @Prop selectedPair: string = '';
  private path(layer: NativeLayoutCompareLayer): string {
    // SVG path commands use physical pixels; the camera and ArkUI lengths use vp.
    const pathScale: number = this.getUIContext().vp2px(this.scalePxPerNm);
    let output: string = '';
    for (const ring of layer.contours) {
      if (ring.length < 3) continue;
      output += `M ${(ring[0].x + this.viewOffsetX) * pathScale} ${(this.viewOffsetY - ring[0].y) * pathScale} `;
      for (let i: number = 1; i < ring.length; i++) output += `L ${(ring[i].x + this.viewOffsetX) * pathScale} ${(this.viewOffsetY - ring[i].y) * pathScale} `;
      output += 'Z ';
    }
    return output;
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      ForEach(this.differences, (layer: NativeLayoutCompareLayer) => {
        if (this.selectedPair.length === 0 || this.selectedPair === `${layer.layerNumber}/${layer.datatype}`) {
          if (layer.previewTruncated) {
            Rect().width(Math.max(2, (layer.maxX - layer.minX) * this.scalePxPerNm))
              .height(Math.max(2, (layer.maxY - layer.minY) * this.scalePxPerNm))
              .position({ x: (layer.minX + this.viewOffsetX) * this.scalePxPerNm,
                y: (this.viewOffsetY - layer.maxY) * this.scalePxPerNm })
              .fill(Color.Transparent).stroke('#E74376').strokeWidth(2)
          } else {
            Path().commands(this.path(layer)).fill('#55F23878').stroke('#E74376').strokeWidth(1.5)
          }
        }
      }, (layer: NativeLayoutCompareLayer) => `${layer.layerNumber}/${layer.datatype}`)
    }.width('100%').height('100%').clip(true).hitTestBehavior(HitTestMode.None)
  }
}
