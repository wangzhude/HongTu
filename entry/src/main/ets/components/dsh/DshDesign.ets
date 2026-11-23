/**
 * DSH-Harmony 原生视觉规范、鸿蒙官方 SymbolGlyph 图标与会话权限选择器模块
 * 全面采用 HarmonyOS 官方 SymbolGlyph 系统符号与 Radio 原生单选控件，零自绘 Path、零 Emoji。
 */
import { hongTuThemeState } from '../../store/ThemeStore';

export type DshPermissionMode = 'auto' | 'review' | 'readonly';

export interface DshPermissionOption {
  value: DshPermissionMode;
  label: string;
  description: string;
  glyph: string;
  badge: string;
}

export const DSH_PERMISSION_OPTIONS: DshPermissionOption[] = [
  {
    value: 'auto',
    label: '自动执行',
    description: 'Agent 直接在当前版图执行绘制、修改与 DRC 复检（支持一键撤销）',
    glyph: 'permission-full-access',
    badge: '默认'
  },
  {
    value: 'review',
    label: '审阅确认',
    description: 'Agent 先生成几何变更预览，待你点击确认后再写入版图',
    glyph: 'permission-workspace-write',
    badge: ''
  },
  {
    value: 'readonly',
    label: '只读问答',
    description: '仅读取分析版图、DRC 与图层结构，禁止任何几何修改',
    glyph: 'permission-read-only',
    badge: ''
  }
];

export function dshPermissionLabel(mode: DshPermissionMode): string {
  if (mode === 'auto') return '自动执行';
  if (mode === 'review') return '审阅确认';
  return '只读问答';
}

export function dshPermissionShortLabel(mode: DshPermissionMode): string {
  if (mode === 'auto') return '自动执行';
  if (mode === 'review') return '审阅确认';
  return '只读';
}

export function resolveDshSymbolResource(glyph: string): Resource {
  switch (glyph) {
    case 'chevron-down':
      return $r('sys.symbol.chevron_down');
    case 'chevron-up':
      return $r('sys.symbol.chevron_up');
    case 'chevron-right':
      return $r('sys.symbol.chevron_right');
    case 'check-outline':
      return $r('sys.symbol.checkmark');
    case 'close-outline':
      return $r('sys.symbol.xmark');
    case 'warning-outline':
      return $r('sys.symbol.exclamationmark_triangle');
    case 'code-outline':
      return $r('sys.symbol.code_square');
    case 'edit-outline':
      return $r('sys.symbol.pencil_line');
    case 'search-outline':
      return $r('sys.symbol.magnifyingglass');
    case 'plan-outline':
      return $r('sys.symbol.doc_text_badge_checkmark');
    case 'permission-full-access':
      return $r('sys.symbol.wand_and_stars');
    case 'permission-workspace-write':
      return $r('sys.symbol.checkmark_circle');
    case 'permission-read-only':
      return $r('sys.symbol.eye');
    case 'undo-outline':
      return $r('sys.symbol.undo');
    case 'focus-outline':
      return $r('sys.symbol.arrow_up_left_and_arrow_down_right');
    case 'camera-outline':
      return $r('sys.symbol.scope');
    case 'ui-outline':
      return $r('sys.symbol.slider_horizontal_2_square');
    case 'web-outline':
      return $r('sys.symbol.square_link_square');
    case 'ask-outline':
      return $r('sys.symbol.info_circle');
    case 'sparkle':
      return $r('sys.symbol.wand_and_stars');
    case 'think-outline':
    default:
      return $r('sys.symbol.ai_edit');
  }
}

export class DshDesign {
  static isDark(): boolean {
    return hongTuThemeState.isDark;
  }

  static base(dark: boolean): string {
    return dark ? '#151517' : '#FFFFFF';
  }

  static subtleSurface(dark: boolean): string {
    return dark ? '#1D1E21' : '#F7F8FA';
  }

  static raised(dark: boolean): string {
    return dark ? '#242527' : '#FFFFFF';
  }

  static deepDiving(dark: boolean): string {
    return dark ? '#7D9ADE' : '#345EBA';
  }

  static overlay(dark: boolean): string {
    return dark ? '#292A2E' : '#FFFFFF';
  }

  static field(dark: boolean): string {
    return dark ? '#2A2C31' : '#F4F5F7';
  }

  static selectedSurface(dark: boolean): string {
    return dark ? '#26324A' : '#EEF3FF';
  }

  static border(dark: boolean): string {
    return dark ? '#3E4047' : '#DDE0E5';
  }

  static divider(dark: boolean): string {
    return dark ? '#2E3036' : '#E9EAEC';
  }

  static textPrimary(dark: boolean): string {
    return dark ? '#F6F7F9' : '#17181B';
  }

  static textSecondary(dark: boolean): string {
    return dark ? '#B5B8BD' : '#585D65';
  }

  static textTertiary(dark: boolean): string {
    return dark ? '#8A8E96' : '#777B84';
  }

  static accent(dark: boolean): string {
    return dark ? '#8AB4FF' : '#3964FE';
  }

  static accentSurface(dark: boolean): string {
    return dark ? '#202D45' : '#EAF0FF';
  }

  static success(dark: boolean): string {
    return dark ? '#7DE3A2' : '#187940';
  }

  static successSurface(dark: boolean): string {
    return dark ? '#173423' : '#ECF8F0';
  }

  static warning(dark: boolean): string {
    return dark ? '#F0B84A' : '#8A5A00';
  }

  static warningSurface(dark: boolean): string {
    return dark ? '#3C3426' : '#FFF7E7';
  }

  static danger(dark: boolean): string {
    return dark ? '#FF9C9C' : '#B3261E';
  }

  static dangerSurface(dark: boolean): string {
    return dark ? '#3B2022' : '#FDEEEE';
  }

  static readonly hitTarget: number = 44;
  static readonly compactControl: number = 30;
  static readonly compactChip: number = 26;
  static readonly radiusBadge: number = 6;
  static readonly radiusCompact: number = 8;
  static readonly radiusControl: number = 10;
  static readonly radiusGroup: number = 16;
  static readonly fontMicro: number = 10;
  static readonly fontCaption: number = 11;
  static readonly fontSection: number = 12;
  static readonly fontCompact: number = 13;
  static readonly fontBody: number = 14;
  static readonly glyphInline: number = 12;
  static readonly glyphCompact: number = 14;
}

/**
 * 鸿蒙官方原生 SymbolGlyph 图标封装（替代旧版手写 Path 线条，支持系统级多倍率矢量抗锯齿渲染）
 */
@Component
export struct DshIcon {
  @Prop glyph: string = 'think-outline';
  @Prop glyphSize: number = 14;
  @Prop color: string = '#61666B';

  build() {
    SymbolGlyph(resolveDshSymbolResource(this.glyph))
      .fontSize(this.glyphSize)
      .fontColor([this.color])
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      .width(this.glyphSize)
      .height(this.glyphSize)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
  }
}

/**
 * 原生会话级 3 档执行权限选择器（采用官方 SymbolGlyph + Radio 原生单选器）
 */
@Component
export struct DshPermissionPicker {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  @Prop currentMode: DshPermissionMode = 'auto';
  @Prop pickerWidth: number = 308;
  onSelect: (mode: DshPermissionMode) => void = (_mode: DshPermissionMode): void => {};
  onClose: () => void = (): void => {};

  private dark(): boolean {
    return this.effectiveIsDark || DshDesign.isDark();
  }

  private optionGlyphColor(opt: DshPermissionOption): string {
    const dark: boolean = this.dark();
    if (opt.value === this.currentMode) {
      return opt.value === 'readonly' ? DshDesign.warning(dark) : DshDesign.accent(dark);
    }
    return DshDesign.textSecondary(dark);
  }

  @Builder
  private optionRow(opt: DshPermissionOption) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 9 }) {
        Stack({ alignContent: Alignment.Center }) {
          DshIcon({
            glyph: opt.glyph,
            glyphSize: DshDesign.glyphCompact,
            color: this.optionGlyphColor(opt)
          })
        }
        .width(28)
        .height(28)
        .borderRadius(DshDesign.radiusBadge)
        .backgroundColor(opt.value === this.currentMode
          ? DshDesign.selectedSurface(this.dark())
          : DshDesign.field(this.dark()))

        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(opt.label)
              .fontSize(DshDesign.fontCompact)
              .fontWeight(opt.value === this.currentMode ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(DshDesign.textPrimary(this.dark()))
              .maxLines(1)
            if (opt.badge.length > 0) {
              Text(opt.badge)
                .fontSize(DshDesign.fontMicro)
                .fontWeight(FontWeight.Medium)
                .fontColor(DshDesign.accent(this.dark()))
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(4)
                .backgroundColor(DshDesign.accentSurface(this.dark()))
            }
          }.width('100%').alignItems(VerticalAlign.Center)

          Text(opt.description)
            .fontSize(DshDesign.fontCaption)
            .fontColor(DshDesign.textTertiary(this.dark()))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Radio({ value: opt.value, group: 'dshPermissionRadioGroup' })
          .checked(opt.value === this.currentMode)
          .width(18)
          .height(18)
          .hitTestBehavior(HitTestMode.None)
      }.width('100%').alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .borderRadius(DshDesign.radiusControl)
    .backgroundColor(opt.value === this.currentMode
      ? DshDesign.selectedSurface(this.dark())
      : Color.Transparent)
    .onClick((): void => {
      this.onSelect(opt.value);
    })
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('Agent 执行权限')
            .fontSize(DshDesign.fontBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(DshDesign.textPrimary(this.dark()))
          Text('控制版图绘制与工具直接执行或审阅确认')
            .fontSize(DshDesign.fontCaption)
            .fontColor(DshDesign.textTertiary(this.dark()))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(13)
            .fontColor([DshDesign.textSecondary(this.dark())])
        }
        .width(28)
        .height(28)
        .padding(0)
        .backgroundColor(DshDesign.field(this.dark()))
        .onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 4, right: 2 })

      Column({ space: 2 }) {
        ForEach(DSH_PERMISSION_OPTIONS, (opt: DshPermissionOption) => {
          this.optionRow(opt)
        }, (opt: DshPermissionOption): string => `${opt.value}:${this.currentMode}`)
      }.width('100%')
    }
    .width(this.pickerWidth)
    .padding(10)
    .backgroundColor(DshDesign.overlay(this.dark()))
    .border({ width: 0.8, color: DshDesign.border(this.dark()) })
    .borderRadius(DshDesign.radiusGroup)
  }
}
