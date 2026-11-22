import { Markdown, MarkdownController } from '@luvi/lv-markdown-in';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import { COLORS } from '../../common/constants';
import { withAlpha } from '../../common/MaterialTokens';
import { UI } from '../../common/UiTokens';
import {
  AiGfmTable,
  AiMarkdownSegment,
  formatGfmTableTsv,
  repairStreamingMarkdown,
  splitMarkdownSegments,
  stripInlineMarkdownDecorators
} from '../../services/AiAgentPresentation';

@Component
struct AiMarkdownChunkView {
  @Prop @Watch('onTextChanged') text: string = '';
  @Prop fontSize: number = UI.fontBody;
  @Prop muted: boolean = false;
  @Prop isCodeFence: boolean = false;
  @Prop rawCopyText: string = '';
  private controller: MarkdownController = new MarkdownController();
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.disposed = false;
    this.configureController();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  onTextChanged(): void {
    if (!this.disposed) {
      this.configureController();
    }
  }

  private configureController(): void {
    const color: string = this.muted ? COLORS.muted : COLORS.ink;
    this.controller.setHtmlPreviewEnable(false).setHtmlPreviewJavaScriptEnable(false)
      .setMermaidEnable(false).setWebPreviewPoolEnable(false)
      .setImageLoadProxy((_src: string): string => '')
      .setImageClickListener((_src: string): boolean => true)
      .setHyperlinkClickListener((_title: string, src: string): boolean => {
        this.openWebLink(src);
        return true;
      })
      .setTextSelectionEnable(false)
      .setTitleColor(color)
      .setTitleSize([this.fontSize + 7, this.fontSize + 5, this.fontSize + 3, this.fontSize + 2, this.fontSize + 1, this.fontSize])
      .setTextColor(color).setTextSize(this.fontSize).setTextLineHeight(this.fontSize + 8)
      .setInlineCodeColor(COLORS.primary).setInlineCodeBackgroundColor(COLORS.surfaceMuted)
      .setCodeBlockTheme(Number.parseInt(COLORS.bg.substring(1, 3), 16) < 128 ? 'dark' : 'light')
      .setCodeBlockIdxState(false).setCodeBlockAutoCollapseEnable(false).setCodeBlockActionAreaVisible(true)
      .setCodeCopyListener((copied: string): void => { this.copyCode(copied); })
      .setQuoteTextColor(COLORS.muted).setQuoteBackgroundColor(COLORS.surfaceMuted)
      .setTableTitleTextColor(color).setTableTitleBackgroundColor(COLORS.surfaceMuted)
      .setTableBackgroundColor(COLORS.surface).setTableBorderRadius(6);
    this.controller.setTableNormalTextColor(color);
    this.controller.setBlockSpacing(8);
  }

  private async copyCode(copied: string): Promise<void> {
    try {
      const originalText: string = this.isCodeFence && this.rawCopyText.length > 0
        ? this.rawCopyText
        : copied.split('$rawfile\u200B(').join('$rawfile(');
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, originalText));
      promptAction.showToast({ message: '代码已复制', duration: 1200 });
    } catch (_) {
      promptAction.showToast({ message: '复制失败，请重试', duration: 1500 });
    }
  }

  private linkToast(message: string): void {
    if (this.disposed) return;
    try { promptAction.showToast({ message: message, duration: 1500 }); } catch (_) {}
  }

  private async openWebLink(source: string): Promise<void> {
    if (this.disposed) return;
    let target: string = '';
    try {
      const value: string = source.trim();
      if (!/^https?:\/\//i.test(value) || /[\u0000-\u0020\u007F\\]/.test(value)) {
        this.linkToast('仅支持打开 HTTP 或 HTTPS 链接');
        return;
      }
      const parsed: url.URL = url.URL.parseURL(value);
      if ((parsed.protocol !== 'https:' && parsed.protocol !== 'http:') || !parsed.hostname ||
        parsed.username.length > 0 || parsed.password.length > 0) {
        this.linkToast('链接无效，无法打开');
        return;
      }
      target = parsed.href;
    } catch (_) {
      this.linkToast('链接无效，无法打开');
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.openLink(target, { appLinkingOnly: false });
    } catch (_) {
      this.linkToast('无法打开链接，请稍后重试');
    }
  }

  build() {
    Markdown({ text: this.text, controller: this.controller, mode: 'text' })
      .width('100%')
  }
}

/**
 * 原生 Markdown + DSH-Harmony 横向可滑动 GFM 表格渲染器：
 * 常规段落与代码块交由 `@luvi/lv-markdown-in`，GFM 宽表格独立渲染于横向 Scroll 容器内，彻底消除侧栏坐标列裁切。
 */
@Component
export struct AiMarkdownBody {
  @Prop @Watch('onContentChanged') content: string = '';
  @Prop @Watch('onStreamingChanged') streaming: boolean = false;
  @Prop fontSize: number = UI.fontBody;
  @Prop muted: boolean = false;
  @Prop code: boolean = false;
  @State segments: AiMarkdownSegment[] = [];
  @State codeFenceText: string = '';
  @State availableWidth: number = 0;
  private updateTimer: number = -1;
  private disposed: boolean = false;
  private codeCopyText: string = '';

  aboutToAppear(): void {
    this.disposed = false;
    this.flushContent();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.clearUpdateTimer();
  }

  onContentChanged(): void {
    if (this.disposed) return;
    if (!this.streaming) {
      this.flushContent();
      return;
    }
    if (this.updateTimer >= 0) return;
    this.updateTimer = setTimeout((): void => {
      this.updateTimer = -1;
      if (!this.disposed) this.flushContent();
    }, 64);
  }

  onStreamingChanged(): void {
    if (!this.streaming && !this.disposed) {
      this.flushContent();
    }
  }

  private clearUpdateTimer(): void {
    if (this.updateTimer >= 0) clearTimeout(this.updateTimer);
    this.updateTimer = -1;
  }

  private flushContent(): void {
    this.clearUpdateTimer();
    const safeRaw: string = this.content.split('$rawfile(').join('$rawfile\u200B(');
    if (this.code) {
      let formatted: string = this.content;
      let language: string = 'text';
      try {
        formatted = JSON.stringify(JSON.parse(this.content), null, 2);
        language = 'json';
      } catch (_) {}
      this.codeCopyText = formatted;
      formatted = formatted.split('$rawfile(').join('$rawfile\u200B(');
      let fenceLength: number = 3;
      const runs: string[] = formatted.match(/`+/g) ?? [];
      for (const run of runs) fenceLength = Math.max(fenceLength, run.length + 1);
      const fence: string = '`'.repeat(fenceLength);
      this.codeFenceText = `${fence}${language}\n${formatted}\n${fence}`;
      this.segments = [];
      return;
    }
    const sourceForParse: string = this.streaming ? repairStreamingMarkdown(safeRaw) : safeRaw;
    this.segments = splitMarkdownSegments(sourceForParse);
  }

  private cellAlign(align: string): TextAlign {
    if (align === 'right') return TextAlign.End;
    if (align === 'center') return TextAlign.Center;
    return TextAlign.Start;
  }

  private async copyTable(table: AiGfmTable): Promise<void> {
    try {
      const tsv: string = formatGfmTableTsv(table);
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, tsv));
      promptAction.showToast({ message: '表格已复制', duration: 1200 });
    } catch (_) {
      promptAction.showToast({ message: '复制失败，请重试', duration: 1500 });
    }
  }

  @Builder
  private NativeScrollableTable(table: AiGfmTable, tableIndex: number) {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(`数据表 · ${table.rows.length} 行 × ${table.headers.length} 列`)
          .fontSize(11)
          .fontColor(COLORS.muted)
          .layoutWeight(1)
        if (this.availableWidth > 0 && table.totalWidth > this.availableWidth + 2) {
          Text('左右滑动完整查看')
            .fontSize(10)
            .fontColor(COLORS.primary)
        }
        Button('复制表格', { type: ButtonType.Normal })
          .height(22)
          .padding({ left: 8, right: 8 })
          .fontSize(10)
          .fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted)
          .borderRadius(6)
          .onClick(() => { this.copyTable(table); })
      }.width('100%').alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 0 }) {
          Row({ space: 0 }) {
            ForEach(table.headers, (headerText: string, colIdx: number) => {
              Column() {
                Text(stripInlineMarkdownDecorators(headerText) || ' ')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(COLORS.ink)
                  .textAlign(this.cellAlign(table.aligns[colIdx] ?? 'left'))
                  .lineHeight(18)
                  .copyOption(CopyOptions.LocalDevice)
                  .width('100%')
              }
              .width(table.columnWidths[colIdx] ?? 120)
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor(COLORS.surfaceMuted)
              .border({
                width: { right: colIdx < table.headers.length - 1 ? 0.6 : 0, bottom: 0.8 },
                color: COLORS.border
              })
            }, (_headerText: string, colIdx: number): string => `th-${tableIndex}-${colIdx}`)
          }.width(table.totalWidth)

          ForEach(table.rows, (rowCells: string[], rowIdx: number) => {
            Row({ space: 0 }) {
              ForEach(rowCells, (cellVal: string, colIdx: number) => {
                Column() {
                  Text(stripInlineMarkdownDecorators(cellVal) || ' ')
                    .fontSize(12)
                    .fontColor(this.muted ? COLORS.muted : COLORS.ink)
                    .textAlign(this.cellAlign(table.aligns[colIdx] ?? 'left'))
                    .lineHeight(18)
                    .copyOption(CopyOptions.LocalDevice)
                    .width('100%')
                }
                .width(table.columnWidths[colIdx] ?? 120)
                .padding({ left: 10, right: 10, top: 7, bottom: 7 })
                .backgroundColor(rowIdx % 2 === 1 ? withAlpha(COLORS.surfaceMuted, 0.45) : COLORS.surface)
                .border({
                  width: {
                    right: colIdx < rowCells.length - 1 ? 0.6 : 0,
                    bottom: rowIdx < table.rows.length - 1 ? 0.5 : 0
                  },
                  color: COLORS.border
                })
              }, (_cellVal: string, colIdx: number): string => `td-${tableIndex}-${rowIdx}-${colIdx}`)
            }.width(table.totalWidth)
          }, (_rowCells: string[], rowIdx: number): string => `tr-${tableIndex}-${rowIdx}`)
        }
        .width(table.totalWidth)
        .alignItems(HorizontalAlign.Start)
      }
      .id(`ai-md-scroll-table-${tableIndex}`)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
      .align(Alignment.TopStart)
      .borderRadius(8)
      .border({ width: 0.8, color: COLORS.border })
      .backgroundColor(COLORS.surface)
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 4, bottom: 4 })
  }

  build() {
    Column({ space: 6 }) {
      if (this.code) {
        AiMarkdownChunkView({
          text: this.codeFenceText,
          fontSize: this.fontSize,
          muted: this.muted,
          isCodeFence: true,
          rawCopyText: this.codeCopyText
        })
      } else {
        ForEach(this.segments, (seg: AiMarkdownSegment, segIdx: number) => {
          if (seg.kind === 'table') {
            this.NativeScrollableTable(seg.table, segIdx)
          } else {
            AiMarkdownChunkView({
              text: seg.text,
              fontSize: this.fontSize,
              muted: this.muted,
              isCodeFence: false,
              rawCopyText: ''
            })
          }
        }, (seg: AiMarkdownSegment, segIdx: number): string =>
          `${segIdx}:${seg.kind}:${seg.kind === 'table' ? `${seg.table.rows.length}x${seg.table.headers.length}:${seg.table.totalWidth}` : seg.text.length}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const nextWidth: number = Number(newArea.width);
      if (Number.isFinite(nextWidth) && Math.abs(nextWidth - this.availableWidth) > 1) {
        this.availableWidth = nextWidth;
      }
    })
  }
}
