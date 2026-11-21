import { Markdown, MarkdownController } from '@luvi/lv-markdown-in';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';

/** Native upstream Markdown rendering; no app-owned Markdown parser or WebView. */
@Component
export struct AiMarkdownBody {
  @Prop @Watch('onContentChanged') content: string = '';
  @Prop @Watch('onStreamingChanged') streaming: boolean = false;
  @Prop fontSize: number = UI.fontBody;
  @Prop muted: boolean = false;
  @Prop code: boolean = false;
  @State renderedText: string = '';
  private controller: MarkdownController = new MarkdownController();
  private updateTimer: number = -1;
  private disposed: boolean = false;
  private codeCopyText: string = '';

  aboutToAppear(): void {
    this.disposed = false;
    this.configureController();
    this.flushContent();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.clearUpdateTimer();
  }

  onContentChanged(): void {
    if (this.disposed) return;
    if (!this.streaming) { this.flushContent(); return; }
    if (this.updateTimer >= 0) return;
    this.updateTimer = setTimeout((): void => {
      this.updateTimer = -1;
      if (!this.disposed) this.flushContent();
    }, 64);
  }

  onStreamingChanged(): void {
    if (!this.streaming && !this.disposed) this.flushContent();
  }

  private clearUpdateTimer(): void {
    if (this.updateTimer >= 0) clearTimeout(this.updateTimer);
    this.updateTimer = -1;
  }

  private flushContent(): void {
    this.clearUpdateTimer();
    // The upstream image component recognizes $rawfile before its image proxy.
    // Break that resource-only marker in the render copy; persisted messages stay exact.
    const safeText: string = this.content.split('$rawfile(').join('$rawfile\u200B(');
    if (!this.code) { this.renderedText = safeText; return; }
    let formatted: string = this.content;
    let language: string = 'text';
    try { formatted = JSON.stringify(JSON.parse(this.content), null, 2); language = 'json'; } catch (_) {}
    this.codeCopyText = formatted;
    formatted = formatted.split('$rawfile(').join('$rawfile\u200B(');
    let fenceLength: number = 3;
    const runs: string[] = formatted.match(/`+/g) ?? [];
    for (const run of runs) fenceLength = Math.max(fenceLength, run.length + 1);
    const fence: string = '`'.repeat(fenceLength);
    this.renderedText = `${fence}${language}\n${formatted}\n${fence}`;
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
      .setTitleSize([this.fontSize + 8, this.fontSize + 6, this.fontSize + 4, this.fontSize + 2, this.fontSize + 1, this.fontSize])
      .setTextColor(color).setTextSize(this.fontSize).setTextLineHeight(this.fontSize + 8)
      .setInlineCodeColor(COLORS.primary).setInlineCodeBackgroundColor(COLORS.surfaceMuted)
      .setCodeBlockTheme(Number.parseInt(COLORS.bg.substring(1, 3), 16) < 128 ? 'dark' : 'light')
      .setCodeBlockIdxState(false).setCodeBlockAutoCollapseEnable(false).setCodeBlockActionAreaVisible(true)
      .setCodeCopyListener((text: string): void => { this.copyCode(text); })
      .setQuoteTextColor(COLORS.muted).setQuoteBackgroundColor(COLORS.surfaceMuted)
      .setTableTitleTextColor(color).setTableTitleBackgroundColor(COLORS.surfaceMuted)
      .setTableBackgroundColor(COLORS.surface).setTableBorderRadius(6);
    this.controller.setTableNormalTextColor(color);
    this.controller.setBlockSpacing(8);
  }

  private async copyCode(text: string): Promise<void> {
    try {
      const originalText: string = this.code ? this.codeCopyText : text.split('$rawfile\u200B(').join('$rawfile(');
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, originalText));
      promptAction.showToast({ message: '代码已复制', duration: 1200 });
    } catch (_) { promptAction.showToast({ message: '复制失败，请重试', duration: 1500 }); }
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
      // Do not include URLs, credentials, or provider exception text in the UI/log.
      this.linkToast('无法打开链接，请稍后重试');
    }
  }

  build() {
    Markdown({ text: this.renderedText, controller: this.controller, mode: 'text' })
      .width('100%')
  }
}
