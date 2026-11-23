import { SymbolGlyphModifier, UIContext } from '@kit.ArkUI';
import { COLORS } from './constants';
import { UI } from './UiTokens';
import { hongTuThemeState } from '../store/ThemeStore';
import { LuminousRenderMode } from '../store/LuminousMaterial';
import { buildLuminousMenuOptions } from '../store/LuminousSurfaceOptions';

/** One semantic symbol family for all native action menus, including submenus. */
function menuSymbol(name: string): Resource {
  switch (name) {
    case 'document': return $r('sys.symbol.doc_text');
    case 'new': return $r('sys.symbol.plus_square');
    case 'open': return $r('sys.symbol.folder');
    case 'recent': return $r('sys.symbol.clock');
    case 'save': return $r('sys.symbol.save');
    case 'saveAs': return $r('sys.symbol.doc_plaintext_and_pencil');
    case 'project': return $r('sys.symbol.doc_plaintext_and_folder');
    case 'search': return $r('sys.symbol.magnifyingglass');
    case 'command': return $r('sys.symbol.keyboard');
    case 'library': return $r('sys.symbol.rectangle_stack');
    case 'compare': return $r('sys.symbol.rectangle_split_2x1');
    case 'technology': return $r('sys.symbol.gearshape');
    case 'verify': return $r('sys.symbol.checkmark_circle');
    case 'ai': return $r('sys.symbol.ai_edit');
    case 'macro': return $r('sys.symbol.code_square');
    case 'view': return $r('sys.symbol.arrow_up_left_and_arrow_down_right');
    case 'edit': return $r('sys.symbol.pencil_line');
    case 'photo': return $r('sys.symbol.rectangle_on_rectangle');
    case 'snapshot': return $r('sys.symbol.square_dashed');
    case 'eye': return $r('sys.symbol.eye');
    case 'eyeOff': return $r('sys.symbol.eye_slash');
    case 'sidebar': return $r('sys.symbol.rectangle_lefthalf_inset_filled');
    case 'inspector': return $r('sys.symbol.rectangle_righthalf_inset_filled');
    case 'reset': return $r('sys.symbol.arrow_2_circlepath');
    case 'preset': return $r('sys.symbol.doc_text_badge_checkmark');
    case 'copy': return $r('sys.symbol.doc_text_on_doc_text');
    case 'paste': return $r('sys.symbol.text_clipboard');
    case 'move': return $r('sys.symbol.move');
    case 'array': return $r('sys.symbol.square_grid_2x2');
    case 'size': return $r('sys.symbol.ruler');
    case 'delete': return $r('sys.symbol.trash');
    case 'rotate': return $r('sys.symbol.arrow_clockwise');
    case 'mirror': return $r('sys.symbol.arrow_left_arrow_right_and_rectangle_portrait');
    case 'zoomIn': return $r('sys.symbol.plus_magnifyingglass');
    case 'zoomOut': return $r('sys.symbol.minus_magnifyingglass');
    case 'alignLeft': return $r('sys.symbol.align_left');
    case 'alignRight': return $r('sys.symbol.align_right');
    case 'alignTop': return $r('sys.symbol.align_top');
    case 'alignBottom': return $r('sys.symbol.align_bottom');
    case 'alignCenter': return $r('sys.symbol.align_center');
    case 'alignMiddle': return $r('sys.symbol.align_middle');
    case 'distributeH': return $r('sys.symbol.rectangle_split_3x1');
    case 'distributeV': return $r('sys.symbol.rectangle_split_1x2');
    case 'union': return $r('sys.symbol.square_and_square');
    case 'subtract': return $r('sys.symbol.rectangle_and_cut');
    case 'intersect': return $r('sys.symbol.square_filled_on_square');
    case 'xor': return $r('sys.symbol.square_square');
    case 'cell': return $r('sys.symbol.square_stack_3d');
    case 'instance': return $r('sys.symbol.rectangle_on_rectangle');
    case 'pcell': return $r('sys.symbol.slider_horizontal_2_square');
    case 'flatten': return $r('sys.symbol.arrow_down_layer');
    case 'selectAll': return $r('sys.symbol.square_dashed');
    case 'selectNone': return $r('sys.symbol.xmark_square');
    case 'layer': return $r('sys.symbol.rectangle_stack');
    case 'trace': return $r('sys.symbol.square_link_square');
    case 'warning': return $r('sys.symbol.exclamationmark_triangle');
    case 'export': return $r('sys.symbol.rectangle_and_arrowshape_turn_up_right');
    case 'measure': return $r('sys.symbol.ruler_measure');
    case 'lock': return $r('sys.symbol.lock');
    case 'unlock': return $r('sys.symbol.lock_open');
    case 'select': return $r('sys.symbol.scope');
    case 'filter': return $r('sys.symbol.funnel');
    case 'path': return $r('sys.symbol.stroke_path');
    case 'text': return $r('sys.symbol.textformat');
    case 'hierarchy': return $r('sys.symbol.square_stack_3d');
    case 'import': return $r('sys.symbol.square_and_arrow_down');
    case 'style': return $r('sys.symbol.paintpalette');
    case 'appearance': return $r('sys.symbol.paintpalette');
    case 'sparkles': return $r('sys.symbol.wand_and_stars');
    case 'rename': return $r('sys.symbol.pencil_line');
    case 'precision': return $r('sys.symbol.ruler_measure');
    case 'grid': return $r('sys.symbol.grid');
    case 'settings': return $r('sys.symbol.slider_horizontal_2');
    default: return $r('sys.symbol.slider_horizontal_2');
  }
}

export function menuIcon(name: string, danger: boolean = false): SymbolGlyphModifier {
  return new SymbolGlyphModifier(menuSymbol(name))
    .fontSize(`${UI.menuIconSize}vp`)
    .fontColor([danger ? COLORS.danger : COLORS.ink]);
}

export function menuSubmenuArrow(): SymbolGlyphModifier | undefined {
  if (AppStorage.get<boolean>('hongtuDesktopWorkspace') !== true) return undefined;
  return new SymbolGlyphModifier($r('sys.symbol.chevron_right'))
    .fontSize(`${UI.menuIconSize}vp`).fontColor([COLORS.muted]);
}

export function menuCheckIcon(selected: boolean): SymbolGlyphModifier | undefined {
  if (!selected) return undefined;
  return new SymbolGlyphModifier($r('sys.symbol.checkmark'))
    .fontSize(`${UI.menuIconSize}vp`).fontColor([COLORS.primary]);
}

function naturalMenuWidth(items: MenuItemOptions[], context: UIContext): number {
  let widest: number = 0;
  for (const item of items) {
    if (item.content === undefined) continue;
    const contentSize: SizeOptions = context.getMeasureUtils().measureTextSize({
      textContent: item.content, fontSize: UI.fontBody
    });
    const contentWidth: number = typeof contentSize.width === 'number' ? context.px2vp(contentSize.width) : 0;
    let rowWidth: number = UI.menuContentPadding * 2 + contentWidth;
    if (item.symbolStartIcon !== undefined || item.startIcon !== undefined) {
      rowWidth += UI.menuIconSize + UI.menuItemGap;
    }
    if (item.labelInfo !== undefined && item.labelInfo !== '') {
      const labelSize: SizeOptions = context.getMeasureUtils().measureTextSize({
        textContent: item.labelInfo, fontSize: UI.fontCaption
      });
      const labelWidth: number = typeof labelSize.width === 'number' ? context.px2vp(labelSize.width) : 0;
      rowWidth += UI.menuItemGap + labelWidth;
    }
    if (item.symbolEndIcon !== undefined || item.endIcon !== undefined || item.builder !== undefined) {
      const endSize: number = item.builder !== undefined &&
        AppStorage.get<boolean>('hongtuDesktopWorkspace') !== true ? UI.menuStackArrowSize : UI.menuIconSize;
      rowWidth += UI.menuItemGap + endSize;
    }
    if ((item.labelInfo === undefined || item.labelInfo === '') &&
      item.symbolEndIcon === undefined && item.endIcon === undefined && item.builder === undefined) {
      rowWidth += UI.menuItemGap;
    }
    widest = Math.max(widest, rowWidth);
  }
  return Math.ceil(widest + UI.menuOuterPadding * 2);
}

class WorkbenchMenuItemStyle implements AttributeModifier<MenuItemAttribute> {
  private danger: boolean;

  constructor(danger: boolean = false) {
    this.danger = danger;
  }

  applyNormalAttribute(item: MenuItemAttribute): void {
    item.contentFont({ size: UI.fontBody })
      .labelFont({ size: UI.fontCaption })
      .contentFontColor(this.danger ? COLORS.danger : COLORS.ink)
      .labelFontColor(COLORS.muted)
      .height(UI.menuRowHeight)
      .selectIcon(false);
  }
}

class WorkbenchMenuStyle implements AttributeModifier<MenuAttribute> {
  private items: MenuItemOptions[];
  private context: UIContext;
  private descendants: MenuItemOptions[][];

  constructor(items: MenuItemOptions[], context: UIContext, descendants: MenuItemOptions[][]) {
    this.items = items;
    this.context = context;
    this.descendants = descendants;
  }

  applyNormalAttribute(menu: MenuAttribute): void {
    let width: number = naturalMenuWidth(this.items, this.context);
    if (AppStorage.get<boolean>('hongtuDesktopWorkspace') !== true) {
      for (const childItems of this.descendants) {
        width = Math.max(width, naturalMenuWidth(childItems, this.context));
      }
    }
    menu.font({ size: UI.fontBody })
      .fontColor(COLORS.ink)
      .width(width)
      .subMenuExpandingMode(AppStorage.get<boolean>('hongtuDesktopWorkspace') === true
        ? SubMenuExpandingMode.SIDE_EXPAND
        : SubMenuExpandingMode.STACK_EXPAND);

    // 子菜单无外层 MenuOptions，当不支持 API 26 官材时为 Menu 节点回退对应档位毛玻璃；
    // API 26 官材激活时不叠加 backgroundBlurStyle，交给宿主 buildLuminousMenuOptions 统一承载折射。
    if (!hongTuThemeState.useSystemImmersiveMaterial()) {
      if (hongTuThemeState.resolveLuminousRenderMode() === LuminousRenderMode.MATERIAL) {
        menu.backgroundBlurStyle(BlurStyle.NONE);
      } else {
        menu.backgroundBlurStyle(BlurStyle.NONE);
      }
    }
  }
}

export const MENU_ITEM_STYLE: AttributeModifier<MenuItemAttribute> = new WorkbenchMenuItemStyle();
export const MENU_DANGER_ITEM_STYLE: AttributeModifier<MenuItemAttribute> = new WorkbenchMenuItemStyle(true);

export function menuStyle(items: MenuItemOptions[], context: UIContext,
  descendants: MenuItemOptions[][] = []): AttributeModifier<MenuAttribute> {
  return new WorkbenchMenuStyle(items, context, descendants);
}

/** 供工作台 `.bindMenu` 快捷构建带四档沉浸光感材质的 MenuOptions。 */
export function workbenchLuminousMenuOptions(base?: MenuOptions): MenuOptions {
  return buildLuminousMenuOptions(
    base,
    hongTuThemeState.luminous,
    hongTuThemeState.resolveLuminousRenderMode(),
    UI.panelRadius
  );
}
