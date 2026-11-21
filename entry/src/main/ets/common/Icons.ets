/**
 * 鸿图矢量图标资源映射（纯矢量 SVG 资源与 HMSymbol，零私有区 Unicode 转义常量）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * SymbolGlyph 参考：
 * https://developer.huawei.com/consumer/cn/doc/harmonyos-references/symbol-glyph
 */

export interface IconResourceSet {
  alignLeft: Resource;
  alignCenter: Resource;
  alignRight: Resource;
  alignTop: Resource;
  alignMiddle: Resource;
  alignBottom: Resource;
  distributeH: Resource;
  distributeV: Resource;
  move: Resource;
  placeInstance: Resource;
  netTrace: Resource;
}

export const IconResource: IconResourceSet = {
  alignLeft: $r('app.media.ic_align_left'),
  alignCenter: $r('app.media.ic_align_center'),
  alignRight: $r('app.media.ic_align_right'),
  alignTop: $r('app.media.ic_align_top'),
  alignMiddle: $r('app.media.ic_align_middle'),
  alignBottom: $r('app.media.ic_align_bottom'),
  distributeH: $r('app.media.ic_distribute_h'),
  distributeV: $r('app.media.ic_distribute_v'),
  move: $r('app.media.ic_move'),
  placeInstance: $r('app.media.ic_place_instance'),
  netTrace: $r('app.media.ic_net_trace'),
};
