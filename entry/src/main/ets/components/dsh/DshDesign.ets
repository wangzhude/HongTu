/**
 * DSH-Harmony 原生视觉规范、矢量图标与会话权限选择器移植模块
 * 源自 DSH-Harmony (NativeDesign.ets / DSHIcon.ets / NativePermissionPicker.ets)
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
 * 纯矢量 DSH 图标（24x24 坐标系按 glyphSize 缩放，零 Emoji、零外部位图依赖）
 */
@Component
export struct DshIcon {
  @Prop glyph: string = 'think-outline';
  @Prop glyphSize: number = 14;
  @Prop color: string = '#61666B';

  private scaledCommands(): string {
    // 使用 HarmonyOS Path 标准 vp2px 换算绘制精锐矢量线条
    const s: number = vp2px(this.glyphSize) / 24.0;
    const p = (x: number, y: number): string => `${(x * s).toFixed(2)} ${(y * s).toFixed(2)}`;
    switch (this.glyph) {
      case 'chevron-down':
        return `M ${p(6, 9)} L ${p(12, 15)} L ${p(18, 9)}`;
      case 'chevron-up':
        return `M ${p(6, 15)} L ${p(12, 9)} L ${p(18, 15)}`;
      case 'chevron-right':
        return `M ${p(9, 6)} L ${p(15, 12)} L ${p(9, 18)}`;
      case 'check-outline':
        return `M ${p(5, 12.5)} L ${p(9.8, 17.2)} L ${p(19.2, 7.2)}`;
      case 'close-outline':
        return `M ${p(6.5, 6.5)} L ${p(17.5, 17.5)} M ${p(17.5, 6.5)} L ${p(6.5, 17.5)}`;
      case 'warning-outline':
        return `M ${p(12, 3.5)} L ${p(21, 19.5)} L ${p(3, 19.5)} Z M ${p(12, 9.5)} L ${p(12, 14)} M ${p(12, 16.8)} L ${p(12, 17.3)}`;
      case 'code-outline':
        return `M ${p(8.5, 7)} L ${p(3.5, 12)} L ${p(8.5, 17)} M ${p(15.5, 7)} L ${p(20.5, 12)} L ${p(15.5, 17)} M ${p(13.5, 5)} L ${p(10.5, 19)}`;
      case 'edit-outline':
        return `M ${p(4, 20)} L ${p(8.5, 19)} L ${p(19, 8.5)} L ${p(15.5, 5)} L ${p(5, 15.5)} Z M ${p(13.5, 7)} L ${p(17, 10.5)}`;
      case 'search-outline':
        return `M ${p(10.5, 4.5)} L ${p(15.5, 6.5)} L ${p(16.5, 11.5)} L ${p(13.5, 15.5)} L ${p(8.5, 16.5)} L ${p(4.5, 13.5)} L ${p(5.5, 7.5)} Z M ${p(15, 15)} L ${p(20, 20)}`;
      case 'plan-outline':
        return `M ${p(4, 6.5)} L ${p(7, 9.5)} L ${p(11, 5.5)} M ${p(13, 7.5)} L ${p(20, 7.5)} M ${p(4, 15.5)} L ${p(7, 18.5)} L ${p(11, 14.5)} M ${p(13, 16.5)} L ${p(20, 16.5)}`;
      case 'permission-full-access':
        return `M ${p(13, 2.5)} L ${p(5, 13.5)} L ${p(11.5, 13.5)} L ${p(10.5, 21.5)} L ${p(19, 10.5)} L ${p(12.5, 10.5)} Z`;
      case 'permission-workspace-write':
        return `M ${p(12, 3)} L ${p(19.5, 6.5)} L ${p(19.5, 12.5)} L ${p(12, 20.5)} L ${p(4.5, 12.5)} L ${p(4.5, 6.5)} Z M ${p(8.8, 12.2)} L ${p(11.2, 14.6)} L ${p(15.6, 9.8)}`;
      case 'permission-read-only':
        return `M ${p(2.5, 12)} L ${p(7, 6.5)} L ${p(12, 5.5)} L ${p(17, 6.5)} L ${p(21.5, 12)} L ${p(17, 17.5)} L ${p(12, 18.5)} L ${p(7, 17.5)} Z M ${p(12, 9.5)} L ${p(14.5, 12)} L ${p(12, 14.5)} L ${p(9.5, 12)} Z`;
      case 'undo-outline':
        return `M ${p(8.5, 7)} L ${p(4, 11.5)} L ${p(8.5, 16)} M ${p(4.5, 11.5)} L ${p(15.5, 11.5)} L ${p(19.5, 14.5)} L ${p(18.5, 18.5)} L ${p(14, 19.5)}`;
      case 'focus-outline':
        return `M ${p(4, 9)} L ${p(4, 4)} L ${p(9, 4)} M ${p(15, 4)} L ${p(20, 4)} L ${p(20, 9)} M ${p(20, 15)} L ${p(20, 20)} L ${p(15, 20)} M ${p(9, 20)} L ${p(4, 20)} L ${p(4, 15)}`;
      case 'sparkle':
        return `M ${p(12, 3)} L ${p(14.3, 9.7)} L ${p(21, 12)} L ${p(14.3, 14.3)} L ${p(12, 21)} L ${p(9.7, 14.3)} L ${p(3, 12)} L ${p(9.7, 9.7)} Z`;
      case 'think-outline':
      default:
        return `M ${p(12, 3.5)} L ${p(16.8, 5.5)} L ${p(18.5, 10)} L ${p(15.2, 14.8)} L ${p(14.8, 17.5)} L ${p(9.2, 17.5)} L ${p(8.8, 14.8)} L ${p(5.5, 10)} L ${p(7.2, 5.5)} Z M ${p(9.5, 20.5)} L ${p(14.5, 20.5)}`;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Path()
        .width(this.glyphSize)
        .height(this.glyphSize)
        .commands(this.scaledCommands())
        .fill(Color.Transparent)
        .stroke(this.color)
        .strokeWidth(1.65)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
    }
    .width(this.glyphSize)
    .height(this.glyphSize)
    .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 移植自 DSH-Harmony NativePermissionPicker.ets：
 * 会话级 3 档执行权限浮层（自动执行 / 审阅确认 / 只读问答）
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

        if (opt.value === this.currentMode) {
          DshIcon({
            glyph: 'check-outline',
            glyphSize: DshDesign.glyphCompact,
            color: DshDesign.accent(this.dark())
          })
        }
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

        Button({ type: ButtonType.Normal }) {
          DshIcon({
            glyph: 'close-outline',
            glyphSize: DshDesign.glyphCompact,
            color: DshDesign.textSecondary(this.dark())
          })
        }
        .width(28)
        .height(28)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(DshDesign.radiusCompact)
        .onClick((): void => { this.onClose(); })
      }.width('100%').padding({ left: 4, right: 2 })

      Column({ space: 2 }) {
        ForEach(DSH_PERMISSION_OPTIONS, (opt: DshPermissionOption) => {
          this.optionRow(opt)
        }, (opt: DshPermissionOption): string => `${opt.value}-${this.currentMode}`)
      }.width('100%')
    }
    .width(this.pickerWidth)
    .padding(10)
    .borderRadius(DshDesign.radiusGroup)
    .backgroundColor(DshDesign.overlay(this.dark()))
    .border({ width: 0.8, color: DshDesign.border(this.dark()) })
  }
}
