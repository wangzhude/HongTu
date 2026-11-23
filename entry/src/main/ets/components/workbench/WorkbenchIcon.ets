import { COLORS } from '../../common/constants';

/** Native system symbols for commands; precise geometry keeps its vector silhouette. */
@Component
export struct WorkbenchIcon {
  @Prop name: string = 'menu';
  @Prop iconSize: number = 20;
  @Prop color: string = COLORS.ink;

  private isGeometry(): boolean {
    return this.name === 'select' || this.name === 'pan' || this.name === 'measure' || this.name === 'rect' ||
      this.name === 'polygon' || this.name === 'path' || this.name === 'instance' || this.name === 'mirror' ||
      this.name === 'mirrorV' || this.name === 'duplicate' || this.name === 'cornerRound' ||
      this.name === 'continuePath' || this.name === 'magnet' || this.name === 'ortho' || this.name === 'loupe' ||
      this.name === 'copy' || this.name === 'slash' || this.name === 'minimize' ||
      this.name === 'think' || this.name === 'model' || this.name === 'dpi' || this.name === 'screenRotate';
  }

  private symbolResource(): Resource {
    switch (this.name) {
      case 'open': return $r('sys.symbol.folder');
      case 'save': return $r('sys.symbol.save');
      case 'undo': return $r('sys.symbol.undo');
      case 'redo': return $r('sys.symbol.redo');
      case 'delete': return $r('sys.symbol.trash');
      case 'fit': return $r('sys.symbol.arrow_up_left_and_arrow_down_right');
      case 'plus': return $r('sys.symbol.plus');
      case 'minus': return $r('sys.symbol.minus');
      case 'reset': return $r('sys.symbol.arrow_2_circlepath');
      case 'rotate': return $r('sys.symbol.arrow_clockwise');
      case 'ai': return $r('sys.symbol.ai_edit');
      case 'search': return $r('sys.symbol.magnifyingglass');
      case 'eye': return $r('sys.symbol.eye');
      case 'eyeOff': return $r('sys.symbol.eye_slash');
      case 'info': return $r('sys.symbol.info_circle');
      case 'warning': return $r('sys.symbol.exclamationmark_triangle');
      case 'chevronLeft': return $r('sys.symbol.chevron_left');
      case 'chevronRight': return $r('sys.symbol.chevron_right');
      case 'chevronDown': return $r('sys.symbol.chevron_down');
      case 'chevronUp': return $r('sys.symbol.chevron_up');
      case 'edit': return $r('sys.symbol.pencil_line');
      case 'close': return $r('sys.symbol.xmark');
      case 'check': return $r('sys.symbol.checkmark');
      case 'text': return $r('sys.symbol.textformat');
      case 'layout': return $r('sys.symbol.square_grid_2x2');
      case 'grid': return $r('sys.symbol.square_grid_2x2');
      case 'cell': return $r('sys.symbol.square_stack_3d');
      case 'verify': return $r('sys.symbol.checkmark_circle');
      case 'data': return $r('sys.symbol.externaldrive_3');
      case 'macro': return $r('sys.symbol.rectangle_stack');
      case 'appearance': return $r('sys.symbol.paintpalette');
      case 'sparkles': return $r('sys.symbol.wand_and_stars');
      case 'settings': return $r('sys.symbol.gearshape');
      default: return $r('sys.symbol.line_3_horizontal');
    }
  }

  private commands(): string {
    switch (this.name) {
      case 'select':
        return 'M5 2L20 13L13 14L10 21Z';
      case 'measure':
        return 'M3 16L16 3L22 9L9 22ZM6 13L9 16M9 10L12 13M12 7L15 10M15 4L18 7';
      case 'rect':
        return 'M4 4H20V20H4Z';
      case 'polygon':
        return 'M7 3H17L22 12L17 21H7L2 12Z';
      case 'path':
        return 'M3 20L9 10L15 14L21 4M2 19H4V21H2ZM8 9H10V11H8ZM14 13H16V15H14ZM20 3H22V5H20Z';
      case 'instance':
        return 'M12 2L22 7V17L12 22L2 17V7ZM2 7L12 12L22 7M12 12V22';
      case 'pan':
        return 'M9 11V5.5A1.5 1.5 0 0 1 12 5.5V10M12 10V4.5A1.5 1.5 0 0 1 15 4.5V10M15 10V6.5A1.5 1.5 0 0 1 18 6.5V14A6 6 0 0 1 12 20H11A6 6 0 0 1 5.6 16.6L3.9 13.2A1.5 1.5 0 0 1 6.5 11.7L9 14V11';
      case 'mirror':
        return 'M12 2V22M9 5L3 12L9 19ZM15 5L21 12L15 19Z';
      case 'mirrorV':
        return 'M2 12H22M5 9L12 3L19 9ZM5 15L12 21L19 15Z';
      case 'duplicate':
        return 'M8 8H19V19H8ZM5 16H4V4H16V5M13.5 11V16M11 13.5H16';
      case 'copy':
        return 'M9 9H19V20H9ZM5 15H4V4H15V5';
      case 'slash':
        return 'M16 4L8 20';
      case 'minimize':
        return 'M5 12H19M9 16L12 19L15 16';
      case 'think':
        return 'M12 3A6 6 0 0 0 8 13.5V16.5A1.5 1.5 0 0 0 9.5 18H14.5A1.5 1.5 0 0 0 16 16.5V13.5A6 6 0 0 0 12 3ZM9.5 21H14.5';
      case 'model':
        return 'M12 2L20 6.5V17.5L12 22L4 17.5V6.5ZM12 12L20 6.5M12 12L4 6.5M12 12V22';
      case 'dpi':
        return 'M4 9V4H9M20 9V4H15M4 15V20H9M20 15V20H15M9 12H15M12 9V15';
      case 'screenRotate':
        return 'M7 4H14A2 2 0 0 1 16 6V18A2 2 0 0 1 14 20H7A2 2 0 0 1 5 18V6A2 2 0 0 1 7 4ZM19 9A5 5 0 0 1 19 16M17 15L19 16.5L21 15';
      case 'cornerRound':
        return 'M5 19V12A7 7 0 0 1 12 5H19M4 18H6V20H4ZM18 4H20V6H18Z';
      case 'continuePath':
        return 'M3 18L9 12L14 15L20 6M16 6H20V10';
      case 'magnet':
        return 'M6 4V11A6 6 0 0 0 18 11V4M6 8H10M14 8H18M10 4V11A2 2 0 0 0 14 11V4';
      case 'ortho':
        return 'M4 19H19V4M4 14H9V19';
      case 'loupe':
        return 'M11 4A7 7 0 1 0 11 18A7 7 0 1 0 11 4ZM16 16L21 21M11 8V14M8 11H14';
      default:
        return 'M3 5H21M3 12H21M3 19H21';
    }
  }

  build() {
    if (this.isGeometry()) {
      Shape() {
        Path().commands(this.commands())
          .fill(this.name === 'select' ? this.color : Color.Transparent)
          .stroke(this.color)
          .strokeWidth('1.7px')
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      }
      .viewPort({ x: '0px', y: '0px', width: '24px', height: '24px' })
      .width(this.iconSize)
      .height(this.iconSize)
      .renderGroup(true)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
    } else {
      SymbolGlyph(this.symbolResource())
        .fontSize(this.iconSize)
        .fontColor([this.color])
        .width(this.iconSize)
        .height(this.iconSize)
        .renderGroup(true)
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
  }
}
