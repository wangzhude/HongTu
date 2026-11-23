import { COLORS } from '../../common/constants';

/**
 * 鸿图统一原生图标组件（HarmonyOS SymbolGlyph 优先 × 专业 CAD 几何轮廓 HiDPI 精配）
 *
 * 1. 凡是鸿蒙系统符号库具备对应语义的动作、导航、对齐、镜像、测量、复制、模型、缩放与面板开关，
 *    100% 路由至官方 `SymbolGlyph($r('sys.symbol.*'))`（含旋转组合，如垂直镜像复用原生镜像符号旋转 90°）；
 * 2. 仅保留 5 个芯片版图 CAD 专属几何绘制态图标（指针选区、正多边形、顶点折线、倒圆角、继续走线）使用 `vp2px` 密度自适应矢量轮廓，
 *    彻底根除旧版硬编码 `'1.7px'` 在 3.25x 高分屏上过细发虚的非原生观感。
 */
@Component
export struct WorkbenchIcon {
  @Prop name: string = 'menu';
  @Prop iconSize: number = 20;
  @Prop color: string = COLORS.ink;

  private isCadDomainSilhouette(): boolean {
    return this.name === 'select' || this.name === 'polygon' || this.name === 'path' ||
      this.name === 'cornerRound' || this.name === 'continuePath' || this.name === 'slash';
  }

  private symbolRotationDeg(): number {
    if (this.name === 'mirrorV') {
      return 90;
    }
    return 0;
  }

  private symbolResource(): Resource {
    switch (this.name) {
      case 'open': return $r('sys.symbol.folder');
      case 'new': return $r('sys.symbol.plus_square');
      case 'save': return $r('sys.symbol.save');
      case 'saveAs': return $r('sys.symbol.doc_plaintext_and_pencil');
      case 'project': return $r('sys.symbol.doc_plaintext_and_folder');
      case 'export': return $r('sys.symbol.rectangle_and_arrowshape_turn_up_right');
      case 'import': return $r('sys.symbol.square_and_arrow_down');
      case 'undo': return $r('sys.symbol.undo');
      case 'redo': return $r('sys.symbol.redo');
      case 'delete': return $r('sys.symbol.trash');
      case 'fit': return $r('sys.symbol.arrow_up_left_and_arrow_down_right');
      case 'dpi': return $r('sys.symbol.arrow_up_left_and_arrow_down_right');
      case 'plus': return $r('sys.symbol.plus');
      case 'minus': return $r('sys.symbol.minus');
      case 'reset': return $r('sys.symbol.arrow_2_circlepath');
      case 'screenRotate': return $r('sys.symbol.arrow_2_circlepath');
      case 'rotate': return $r('sys.symbol.arrow_clockwise');
      case 'mirror':
      case 'mirrorV':
        return $r('sys.symbol.arrow_left_arrow_right_and_rectangle_portrait');
      case 'copy': return $r('sys.symbol.doc_text_on_doc_text');
      case 'paste': return $r('sys.symbol.text_clipboard');
      case 'duplicate': return $r('sys.symbol.plus_square');
      case 'loupe': return $r('sys.symbol.plus_magnifyingglass');
      case 'zoomOut': return $r('sys.symbol.minus_magnifyingglass');
      case 'measure': return $r('sys.symbol.ruler_measure');
      case 'ruler': return $r('sys.symbol.ruler');
      case 'rect': return $r('sys.symbol.square_square');
      case 'instance': return $r('sys.symbol.rectangle_on_rectangle');
      case 'pan':
      case 'move':
        return $r('sys.symbol.move');
      case 'magnet': return $r('sys.symbol.scope');
      case 'ortho': return $r('sys.symbol.stroke_path');
      case 'minimize': return $r('sys.symbol.chevron_down');
      case 'think': return $r('sys.symbol.wand_and_stars');
      case 'model': return $r('sys.symbol.square_stack_3d');
      case 'code':
      case 'python':
        return $r('sys.symbol.code_square');
      case 'keyboard': return $r('sys.symbol.keyboard');
      case 'sidebar': return $r('sys.symbol.rectangle_lefthalf_inset_filled');
      case 'inspector': return $r('sys.symbol.rectangle_righthalf_inset_filled');
      case 'compare': return $r('sys.symbol.rectangle_split_2x1');
      case 'stack':
      case 'flatten':
        return $r('sys.symbol.arrow_down_layer');
      case 'filter': return $r('sys.symbol.funnel');
      case 'lock': return $r('sys.symbol.lock');
      case 'unlock': return $r('sys.symbol.lock_open');
      case 'trace':
      case 'web':
        return $r('sys.symbol.square_link_square');
      case 'union': return $r('sys.symbol.square_and_square');
      case 'subtract': return $r('sys.symbol.rectangle_and_cut');
      case 'alignLeft': return $r('sys.symbol.align_left');
      case 'alignRight': return $r('sys.symbol.align_right');
      case 'alignTop': return $r('sys.symbol.align_top');
      case 'alignBottom': return $r('sys.symbol.align_bottom');
      case 'alignCenter': return $r('sys.symbol.align_center');
      case 'alignMiddle': return $r('sys.symbol.align_middle');
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
      case 'grid': return $r('sys.symbol.grid');
      case 'cell': return $r('sys.symbol.square_stack_3d');
      case 'verify': return $r('sys.symbol.checkmark_circle');
      case 'data': return $r('sys.symbol.externaldrive_3');
      case 'macro': return $r('sys.symbol.rectangle_stack');
      case 'appearance': return $r('sys.symbol.paintpalette');
      case 'sparkles': return $r('sys.symbol.wand_and_stars');
      case 'settings': return $r('sys.symbol.gearshape');
      case 'clock': return $r('sys.symbol.clock');
      default: return $r('sys.symbol.line_3_horizontal');
    }
  }

  private scaledCadCommands(): string {
    const s: number = vp2px(this.iconSize) / 24.0;
    const c = (v: number): string => (v * s).toFixed(2);
    switch (this.name) {
      case 'select':
        return `M${c(5)} ${c(2.5)} L${c(19.5)} ${c(13)} L${c(12.6)} ${c(14.2)} L${c(9.8)} ${c(20.8)} Z`;
      case 'polygon':
        return `M${c(7)} ${c(3.5)} H${c(17)} L${c(21.5)} ${c(12)} L${c(17)} ${c(20.5)} H${c(7)} L${c(2.5)} ${c(12)} Z`;
      case 'path':
        return `M${c(3.5)} ${c(19.5)} L${c(9.2)} ${c(9.8)} L${c(15)} ${c(13.8)} L${c(20.5)} ${c(4.5)} ` +
          `M${c(2.3)} ${c(18.3)} H${c(4.7)} V${c(20.7)} H${c(2.3)} Z ` +
          `M${c(8)} ${c(8.6)} H${c(10.4)} V${c(11)} H${c(8)} Z ` +
          `M${c(13.8)} ${c(12.6)} H${c(16.2)} V${c(15)} H${c(13.8)} Z ` +
          `M${c(19.3)} ${c(3.3)} H${c(21.7)} V${c(5.7)} H${c(19.3)} Z`;
      case 'cornerRound':
        return `M${c(5)} ${c(19)} V${c(12)} A${c(7)} ${c(7)} 0 0 1 ${c(12)} ${c(5)} H${c(19)}`;
      case 'continuePath':
        return `M${c(3.5)} ${c(18)} L${c(9)} ${c(12)} L${c(14)} ${c(15)} L${c(20)} ${c(6)} M${c(15.5)} ${c(6)} H${c(20)} V${c(10.5)}`;
      case 'slash':
      default:
        return `M${c(15.5)} ${c(4.5)} L${c(8.5)} ${c(19.5)}`;
    }
  }

  build() {
    if (this.isCadDomainSilhouette()) {
      Stack({ alignContent: Alignment.Center }) {
        Path()
          .width(this.iconSize)
          .height(this.iconSize)
          .commands(this.scaledCadCommands())
          .fill(this.name === 'select' ? this.color : Color.Transparent)
          .stroke(this.color)
          .strokeWidth(1.75)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      }
      .width(this.iconSize)
      .height(this.iconSize)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
    } else {
      SymbolGlyph(this.symbolResource())
        .fontSize(this.iconSize)
        .fontColor([this.color])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .rotate({ angle: this.symbolRotationDeg() })
        .width(this.iconSize)
        .height(this.iconSize)
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
  }
}
