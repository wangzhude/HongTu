/**
 * 完整移植自 DSH-Harmony 原版对话过程组件群：
 * - NativeProcessView.ets + NativeProcessStepView.ets + NativeToolCallView.ets（扁平无框多步推理与工具时间线）
 * - NativeRunningTail.ets + NativeRunningLabel.ets（底部独立时钟“深度求索中，用时 Xs ···”，不触发列表重排）
 * - NativeTaskDock.ets + NativePlanView.ets（底部任务计划进度坞）
 * - NativeTurnChangesView.ets（本轮版图变更回执条：+图元 / +端口 / DRC 状态 / 定位 / 一键撤销）
 */
import { Chip, ChipSize, SymbolGlyphModifier } from '@kit.ArkUI';
import { DshDesign, DshIcon } from './DshDesign';
import type {
  AiAskUserExchange,
  AiAskUserOption,
  AiAskUserRequest,
  AiChatAttachment,
  AiChatToolState,
  AiProcessStep,
  DshWebSearchItem
} from '../../services/AiService';
import { formatAttachmentSize } from '../../services/AiAttachmentService';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import {
  describeAiToolCall,
  extractAiPlan,
  oneLineStepPreview,
  summarizeProcessSteps,
  AiPlanStepView,
  AiToolField
} from '../../services/AiAgentPresentation';
import { AiMarkdownBody } from '../workbench/AiMarkdownBody';

export interface DshTurnChangeSummary {
  addedShapes: number;
  deletedShapes: number;
  addedPorts: number;
  drcSummary: string;
  cellName: string;
  canUndo: boolean;
}

function resolveDshToolIcon(toolName: string): string {
  if (toolName === 'capture_screenshot') {
    return 'camera-outline';
  }
  if (toolName === 'inspect_workbench_ui' || toolName === 'automate_workbench_ui' || toolName === 'manage_workbench') {
    return 'ui-outline';
  }
  if (toolName === 'web_search' || toolName === 'web_fetch') {
    return 'web-outline';
  }
  if (toolName === 'ask_user') {
    return 'ask-outline';
  }
  if (toolName === 'inspect_layout' || toolName === 'query_layout' || toolName === 'query_editor' ||
    toolName === 'list_native_tools' || toolName === 'read_native_tool' || toolName === 'inspect_attachments') {
    return 'search-outline';
  }
  if (toolName === 'todo_write' || toolName === 'write_plan' || toolName === 'update_task_status') {
    return 'plan-outline';
  }
  if (toolName === 'execute_klayout_python' || toolName === 'execute_layout_python' || toolName === 'call_native_tool') {
    return 'code-outline';
  }
  if (toolName === 'run_drc' || toolName === 'manage_verification') {
    return 'check-outline';
  }
  return 'edit-outline';
}

interface DshToolDiffBadge {
  added: number;
  removed: number;
}

function parseToolDiffBadge(tool: AiChatToolState): DshToolDiffBadge {
  const none: DshToolDiffBadge = { added: 0, removed: 0 };
  if (!tool.result || tool.result.length === 0) return none;
  try {
    const parsed: Record<string, Object> = JSON.parse(tool.result) as Record<string, Object>;
    const addedVal: Object | undefined = parsed['addedShapes'] ?? parsed['addedCount'] ?? parsed['shapeCount'] ?? parsed['operations'];
    const removedVal: Object | undefined = parsed['deletedShapes'] ?? parsed['deletedCount'];
    const added: number = typeof addedVal === 'number' && Number.isFinite(addedVal) && addedVal > 0 ? Math.floor(addedVal) : 0;
    const removed: number = typeof removedVal === 'number' && Number.isFinite(removedVal) && removedVal > 0 ? Math.floor(removedVal) : 0;
    return { added, removed };
  } catch (_) {
    return none;
  }
}

/**
 * 独立秒表标签（源自 NativeRunningLabel.ets）：每秒局部刷新，绝不触发父对话流重排
 */
@Component
struct DshRunningClockLabel {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  private dark(): boolean { return this.effectiveIsDark || DshDesign.isDark(); }
  @Prop startedAt: number = 0;
  @Prop statusHint: string = '';
  @State private elapsedSec: number = 0;
  private clockTimer: number = -1;

  aboutToAppear(): void {
    this.syncElapsed();
    this.clockTimer = setInterval((): void => {
      this.syncElapsed();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }

  private syncElapsed(): void {
    if (this.startedAt <= 0) {
      this.elapsedSec = 0;
      return;
    }
    this.elapsedSec = Math.max(0, Math.floor((Date.now() - this.startedAt) / 1000));
  }

  private formatElapsed(): string {
    if (this.elapsedSec < 60) {
      return `${this.elapsedSec}s`;
    }
    const mins: number = Math.floor(this.elapsedSec / 60);
    const secs: number = this.elapsedSec % 60;
    return `${mins}m ${secs}s`;
  }

  build() {
    Row({ space: 6 }) {
      Text(`深度求索中，用时 ${this.formatElapsed()} ···`)
        .fontSize(DshDesign.fontSection)
        .fontWeight(FontWeight.Medium)
        .fontColor(DshDesign.deepDiving(this.dark()))
        .maxLines(1)
      if (this.statusHint.length > 0) {
        Text(this.statusHint)
          .fontSize(DshDesign.fontCaption)
          .fontColor(DshDesign.textTertiary(this.dark()))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
    }.layoutWeight(1).alignItems(VerticalAlign.Center)
  }
}

/**
 * 移植自 DSH-Harmony NativeRunningTail.ets
 */
@Component
export struct DshRunningTail {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  private dark(): boolean { return this.effectiveIsDark || DshDesign.isDark(); }
  @Prop startedAt: number = 0;
  @Prop statusHint: string = '';

  build() {
    Column({ space: 0 }) {
      Divider()
        .strokeWidth(0.5)
        .color(DshDesign.divider(this.dark()))
        .opacity(0.75)
      Row({ space: 8 }) {
        LoadingProgress()
          .width(15)
          .height(15)
          .color(DshDesign.deepDiving(this.dark()))
        DshRunningClockLabel({
          startedAt: this.startedAt,
          statusHint: this.statusHint
        })
      }
      .width('100%')
      .height(28)
      .padding({ left: 4, right: 4 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .margin({ top: 4 })
  }
}

/**
 * 移植自 DSH-Harmony NativeTaskDock.ets + NativePlanView.ets：
 * 紧凑折叠式任务计划坞（锚定在输入框上方）
 */
@Component
export struct DshTaskDock {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  private dark(): boolean { return this.effectiveIsDark || DshDesign.isDark(); }
  @Prop steps: AiPlanStepView[] = [];
  @State private expanded: boolean = false;

  private completedCount(): number {
    return this.steps.filter((s: AiPlanStepView): boolean => s.status === 'completed').length;
  }

  private activeTitle(): string {
    const running: AiPlanStepView | undefined = this.steps.find((s: AiPlanStepView): boolean => s.status === 'in_progress');
    if (running !== undefined) return running.content;
    const pending: AiPlanStepView | undefined = this.steps.find((s: AiPlanStepView): boolean => s.status !== 'completed');
    if (pending !== undefined) return pending.content;
    return this.steps.length > 0 ? this.steps[this.steps.length - 1].content : '';
  }

  build() {
    if (this.steps.length > 0) {
      Column({ space: this.expanded ? 6 : 0 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            DshIcon({
              glyph: 'plan-outline',
              glyphSize: DshDesign.glyphCompact,
              color: DshDesign.accent(this.dark())
            })
            Text(`任务进度 ${this.completedCount()}/${this.steps.length}`)
              .fontSize(DshDesign.fontCaption)
              .fontWeight(FontWeight.Medium)
              .fontColor(DshDesign.textPrimary(this.dark()))
            Text('·')
              .fontSize(DshDesign.fontCaption)
              .fontColor(DshDesign.textTertiary(this.dark()))
            Text(this.activeTitle())
              .fontSize(DshDesign.fontCaption)
              .fontColor(DshDesign.textSecondary(this.dark()))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            DshIcon({
              glyph: this.expanded ? 'chevron-up' : 'chevron-down',
              glyphSize: DshDesign.glyphInline,
              color: DshDesign.textTertiary(this.dark())
            })
          }.width('100%').alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height(28)
        .padding({ left: 8, right: 8 })
        .backgroundColor(Color.Transparent)
        .onClick((): void => { this.expanded = !this.expanded; })

        if (this.expanded) {
          Column({ space: 4 }) {
            ForEach(this.steps, (item: AiPlanStepView) => {
              Row({ space: 7 }) {
                DshIcon({
                  glyph: item.status === 'completed' ? 'check-outline' : 'plan-outline',
                  glyphSize: 12,
                  color: item.status === 'completed'
                    ? DshDesign.success(this.dark())
                    : (item.status === 'in_progress'
                      ? DshDesign.accent(this.dark())
                      : DshDesign.textTertiary(this.dark()))
                })
                Text(item.content)
                  .fontSize(DshDesign.fontCaption)
                  .fontColor(item.status === 'completed'
                    ? DshDesign.textTertiary(this.dark())
                    : DshDesign.textPrimary(this.dark()))
                  .layoutWeight(1)
                  .maxLines(2)
              }.width('100%').alignItems(VerticalAlign.Center)
            }, (item: AiPlanStepView): string => `${item.id}:${item.status}:${item.content}`)
          }
          .width('100%')
          .padding({ left: 10, right: 10, bottom: 8 })
        }
      }
      .width('100%')
      .backgroundColor(DshDesign.subtleSurface(this.dark()))
      .border({ width: 0.6, color: DshDesign.border(this.dark()) })
      .borderRadius(DshDesign.radiusControl)
    }
  }
}

/**
 * 移植自 DSH-Harmony NativeTurnChangesView.ets：
 * 本轮版图变更回执条（显示新增/删除图元、端口与 DRC 结果，支持一键定位与撤销）
 */
@Component
export struct DshTurnChangesCard {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  private dark(): boolean { return this.effectiveIsDark || DshDesign.isDark(); }
  @Prop summaryText: string = '';
  @Prop canUndo: boolean = false;
  onFitView: () => void = (): void => {};
  onUndo: () => void = (): void => {};

  build() {
    if (this.summaryText.length > 0) {
      Row({ space: 8 }) {
        DshIcon({
          glyph: 'check-outline',
          glyphSize: DshDesign.glyphCompact,
          color: DshDesign.success(this.dark())
        })
        Text(this.summaryText)
          .fontSize(DshDesign.fontCaption)
          .fontColor(DshDesign.textSecondary(this.dark()))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Button({ type: ButtonType.Normal }) {
          Row({ space: 3 }) {
            DshIcon({
              glyph: 'focus-outline',
              glyphSize: 11,
              color: DshDesign.accent(this.dark())
            })
            Text('适配')
              .fontSize(DshDesign.fontMicro)
              .fontColor(DshDesign.accent(this.dark()))
          }.alignItems(VerticalAlign.Center)
        }
        .height(24)
        .padding({ left: 7, right: 7 })
        .backgroundColor(DshDesign.accentSurface(this.dark()))
        .borderRadius(DshDesign.radiusBadge)
        .onClick((): void => { this.onFitView(); })

        if (this.canUndo) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 3 }) {
              DshIcon({
                glyph: 'undo-outline',
                glyphSize: 11,
                color: DshDesign.textSecondary(this.dark())
              })
              Text('撤销')
                .fontSize(DshDesign.fontMicro)
                .fontColor(DshDesign.textSecondary(this.dark()))
            }.alignItems(VerticalAlign.Center)
          }
          .height(24)
          .padding({ left: 7, right: 7 })
          .backgroundColor(DshDesign.field(this.dark()))
          .borderRadius(DshDesign.radiusBadge)
          .onClick((): void => { this.onUndo(); })
        }
      }
      .width('100%')
      .padding({ left: 10, right: 8, top: 6, bottom: 6 })
      .backgroundColor(DshDesign.subtleSurface(this.dark()))
      .border({ width: 0.6, color: DshDesign.border(this.dark()) })
      .borderRadius(DshDesign.radiusControl)
      .margin({ top: 4, bottom: 2 })
    }
  }
}

/**
 * 完整移植自 DSH-Harmony NativeProcessView.ets + NativeProcessStepView.ets + NativeToolCallView.ets：
 * 去边框扁平多步时间线，支持逐字实时流式展开当前活跃思考步与点开任意历史思考/工具详情
 */
@Component
export struct DshProcessView {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  private dark(): boolean { return this.effectiveIsDark || DshDesign.isDark(); }
  @Prop turnKey: string = 'live';
  @Prop isLive: boolean = false;
  @Prop defaultExpanded: boolean = true;
  @Prop steps: AiProcessStep[] = [];
  @Prop activeThinkId: string = '';
  @Prop activeThinkText: string = '';
  @State private expanded: boolean = true;
  @State private manualOpenIds: string[] = [];
  @State private manualClosedIds: string[] = [];
  @State private rawToolIds: string[] = [];
  private activeThinkScroller: Scroller = new Scroller();
  private thinkViewportH: number = 0;
  private thinkContentH: number = 0;

  aboutToAppear(): void {
    this.expanded = this.defaultExpanded;
  }

  private isStepOpen(step: AiProcessStep, isLast: boolean): boolean {
    if (this.manualOpenIds.includes(step.id)) return true;
    if (this.manualClosedIds.includes(step.id)) return false;
    if (this.isLive && step.kind === 'thinking' && (step.id === this.activeThinkId || (step.status === 'running' && isLast))) {
      return true;
    }
    if (step.kind === 'tool' && step.status === 'failed') {
      return true;
    }
    return false;
  }

  private toggleStep(step: AiProcessStep, isLast: boolean): void {
    const currentlyOpen: boolean = this.isStepOpen(step, isLast);
    if (currentlyOpen) {
      this.manualOpenIds = this.manualOpenIds.filter((id: string): boolean => id !== step.id);
      if (!this.manualClosedIds.includes(step.id)) {
        this.manualClosedIds = this.manualClosedIds.concat([step.id]);
      }
    } else {
      this.manualClosedIds = this.manualClosedIds.filter((id: string): boolean => id !== step.id);
      if (!this.manualOpenIds.includes(step.id)) {
        this.manualOpenIds = this.manualOpenIds.concat([step.id]);
      }
    }
  }

  private toggleRawJson(toolId: string): void {
    if (this.rawToolIds.includes(toolId)) {
      this.rawToolIds = this.rawToolIds.filter((id: string): boolean => id !== toolId);
    } else {
      this.rawToolIds = this.rawToolIds.concat([toolId]);
    }
  }

  private thinkingOrdinal(stepId: string): string {
    const thinkSteps: AiProcessStep[] = this.steps.filter((s: AiProcessStep): boolean => s.kind === 'thinking');
    if (thinkSteps.length <= 1) return '思考';
    const pos: number = thinkSteps.findIndex((s: AiProcessStep): boolean => s.id === stepId);
    return pos >= 0 ? `思考 #${pos + 1}` : '思考';
  }

  private extractTools(): AiChatToolState[] {
    const out: AiChatToolState[] = [];
    for (let i = 0; i < this.steps.length; i++) {
      const t: AiChatToolState | undefined = this.steps[i].tool;
      if (this.steps[i].kind === 'tool' && t !== undefined) {
        out.push(t);
      }
    }
    return out;
  }

  @Builder
  private renderToolStep(step: AiProcessStep, tool: AiChatToolState, isLast: boolean) {
    Column({ space: this.isStepOpen(step, isLast) ? 4 : 0 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          if (tool.status === 'running') {
            LoadingProgress()
              .width(13)
              .height(13)
              .color(DshDesign.accent(this.dark()))
          } else {
            DshIcon({
              glyph: tool.status === 'failed' ? 'warning-outline' : resolveDshToolIcon(tool.name),
              glyphSize: DshDesign.glyphCompact,
              color: tool.status === 'failed'
                ? DshDesign.danger(this.dark())
                : DshDesign.textTertiary(this.dark())
            })
          }

          Text(describeAiToolCall(tool, false).title)
            .fontSize(DshDesign.fontSection)
            .fontWeight(FontWeight.Medium)
            .fontColor(tool.status === 'failed'
              ? DshDesign.danger(this.dark())
              : DshDesign.textSecondary(this.dark()))
            .maxLines(1)

          if (describeAiToolCall(tool, this.isLive).inlineTarget.length > 0 && !this.isStepOpen(step, isLast)) {
            Text('·')
              .fontSize(DshDesign.fontSection)
              .fontColor(DshDesign.textTertiary(this.dark()))
            Text(describeAiToolCall(tool, this.isLive).inlineTarget)
              .fontSize(DshDesign.fontSection)
              .fontColor(DshDesign.textTertiary(this.dark()))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          } else {
            Blank().layoutWeight(1)
          }

          if (parseToolDiffBadge(tool).added > 0) {
            Text(`+${parseToolDiffBadge(tool).added}`)
              .fontSize(DshDesign.fontMicro)
              .fontWeight(FontWeight.Medium)
              .fontColor(DshDesign.success(this.dark()))
          }
          if (parseToolDiffBadge(tool).removed > 0) {
            Text(`-${parseToolDiffBadge(tool).removed}`)
              .fontSize(DshDesign.fontMicro)
              .fontWeight(FontWeight.Medium)
              .fontColor(DshDesign.danger(this.dark()))
          }
          if (tool.status === 'failed') {
            Text('失败')
              .fontSize(DshDesign.fontMicro)
              .fontColor(DshDesign.danger(this.dark()))
          }

          DshIcon({
            glyph: this.isStepOpen(step, isLast) ? 'chevron-up' : 'chevron-right',
            glyphSize: DshDesign.glyphInline,
            color: DshDesign.textTertiary(this.dark())
          })
        }.width('100%').alignItems(VerticalAlign.Center)
      }
      .height(DshDesign.compactControl)
      .width('100%')
      .padding({ left: 4, right: 4 })
      .backgroundColor(Color.Transparent)
      .borderRadius(DshDesign.radiusCompact)
      .onClick((): void => { this.toggleStep(step, isLast); })

      if (this.isStepOpen(step, isLast)) {
        Column({ space: 6 }) {
          if (describeAiToolCall(tool, false).fields.length > 0) {
            Column({ space: 4 }) {
              ForEach(describeAiToolCall(tool, false).fields, (f: AiToolField, fIdx: number) => {
                Row({ space: 8 }) {
                  Text(f.label)
                    .fontSize(DshDesign.fontCaption)
                    .fontColor(DshDesign.textTertiary(this.dark()))
                    .width(64)
                  Text(f.value)
                    .fontSize(DshDesign.fontCaption)
                    .fontFamily(f.accent ? 'monospace' : 'HarmonyOS Sans')
                    .fontColor(tool.status === 'failed' && f.label.includes('提示')
                      ? DshDesign.danger(this.dark())
                      : DshDesign.textPrimary(this.dark()))
                    .layoutWeight(1)
                    .wordBreak(WordBreak.BREAK_WORD)
                    .copyOption(CopyOptions.LocalDevice)
                }.width('100%').alignItems(VerticalAlign.Top)
              }, (f: AiToolField, fIdx: number): string => `${fIdx}:${f.label}:${f.value}`)
            }.width('100%')
          } else if (tool.result.length > 0) {
            Text(tool.result.substring(0, 600))
              .fontSize(DshDesign.fontCaption)
              .fontColor(tool.status === 'failed'
                ? DshDesign.danger(this.dark())
                : DshDesign.textSecondary(this.dark()))
              .width('100%')
              .wordBreak(WordBreak.BREAK_WORD)
              .copyOption(CopyOptions.LocalDevice)
          }

          if (tool.arguments.length > 0 || tool.result.length > 0) {
            Button(this.rawToolIds.includes(tool.id) ? '收起原始参数/返回' : '查看原始 JSON', { type: ButtonType.Normal })
              .height(20)
              .padding(0)
              .fontSize(DshDesign.fontMicro)
              .fontColor(DshDesign.accent(this.dark()))
              .backgroundColor(Color.Transparent)
              .onClick((): void => { this.toggleRawJson(tool.id); })

            if (this.rawToolIds.includes(tool.id)) {
              if (tool.arguments.length > 0) {
                AiMarkdownBody({ content: tool.arguments, code: true, fontSize: 11, streaming: false }).width('100%')
              }
              if (tool.result.length > 0) {
                AiMarkdownBody({ content: tool.result, code: true, fontSize: 11, streaming: false }).width('100%')
              }
            }
          }
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .backgroundColor(DshDesign.field(this.dark()))
        .borderRadius(DshDesign.radiusCompact)
        .alignItems(HorizontalAlign.Start)
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renderThinkingStep(step: AiProcessStep, isLast: boolean) {
    Column({ space: this.isStepOpen(step, isLast) ? 4 : 0 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          if (this.isLive && (step.id === this.activeThinkId || step.status === 'running')) {
            LoadingProgress()
              .width(13)
              .height(13)
              .color(DshDesign.deepDiving(this.dark()))
          } else {
            DshIcon({
              glyph: 'think-outline',
              glyphSize: DshDesign.glyphCompact,
              color: DshDesign.textTertiary(this.dark())
            })
          }

          Text(this.thinkingOrdinal(step.id))
            .fontSize(DshDesign.fontSection)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.isLive && step.id === this.activeThinkId
              ? DshDesign.deepDiving(this.dark())
              : DshDesign.textSecondary(this.dark()))
            .maxLines(1)

          if (!this.isStepOpen(step, isLast)) {
            Text('·')
              .fontSize(DshDesign.fontSection)
              .fontColor(DshDesign.textTertiary(this.dark()))
            Text(oneLineStepPreview(step.id === this.activeThinkId && this.activeThinkText.length > 0 ? this.activeThinkText : step.text, 76))
              .fontSize(DshDesign.fontSection)
              .fontColor(DshDesign.textTertiary(this.dark()))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          } else {
            Text(`${(step.id === this.activeThinkId && this.activeThinkText.length > 0 ? this.activeThinkText : step.text).length} 字`)
              .fontSize(DshDesign.fontMicro)
              .fontColor(DshDesign.textTertiary(this.dark()))
            Blank().layoutWeight(1)
          }

          DshIcon({
            glyph: this.isStepOpen(step, isLast) ? 'chevron-up' : 'chevron-right',
            glyphSize: DshDesign.glyphInline,
            color: DshDesign.textTertiary(this.dark())
          })
        }.width('100%').alignItems(VerticalAlign.Center)
      }
      .height(DshDesign.compactControl)
      .width('100%')
      .padding({ left: 4, right: 4 })
      .backgroundColor(Color.Transparent)
      .borderRadius(DshDesign.radiusCompact)
      .onClick((): void => { this.toggleStep(step, isLast); })

      if (this.isStepOpen(step, isLast)) {
        if (this.isLive && step.id === this.activeThinkId) {
          Scroll(this.activeThinkScroller) {
            Text(this.activeThinkText.length > 0 ? this.activeThinkText : step.text)
              .fontSize(DshDesign.fontSection)
              .lineHeight(19)
              .fontColor(DshDesign.textSecondary(this.dark()))
              .wordBreak(WordBreak.BREAK_WORD)
              .copyOption(CopyOptions.LocalDevice)
              .width('100%')
              .onAreaChange((_oldA: Area, newA: Area): void => {
                const nh: number = Number(newA.height);
                if (Number.isFinite(nh) && Math.abs(nh - this.thinkContentH) > 0.5) {
                  this.thinkContentH = nh;
                  if (this.thinkViewportH > 0 && nh > this.thinkViewportH) {
                    try {
                      this.activeThinkScroller.scrollTo({
                        xOffset: 0,
                        yOffset: Math.max(0, nh - this.thinkViewportH),
                        animation: false
                      });
                    } catch (_) {}
                  }
                }
              })
          }
          .width('100%')
          .padding(8)
          .backgroundColor(DshDesign.field(this.dark()))
          .borderRadius(DshDesign.radiusCompact)
          .constraintSize({ maxHeight: 172 })
          .align(Alignment.TopStart)
          .scrollBar(BarState.Auto)
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
          .onAreaChange((_oldV: Area, newV: Area): void => {
            const nv: number = Number(newV.height);
            if (Number.isFinite(nv) && Math.abs(nv - this.thinkViewportH) > 0.5) {
              this.thinkViewportH = nv;
            }
          })
        } else {
          Scroll() {
            Text(step.text)
              .fontSize(DshDesign.fontSection)
              .lineHeight(19)
              .fontColor(DshDesign.textSecondary(this.dark()))
              .wordBreak(WordBreak.BREAK_WORD)
              .copyOption(CopyOptions.LocalDevice)
              .width('100%')
          }
          .width('100%')
          .padding(8)
          .backgroundColor(DshDesign.field(this.dark()))
          .borderRadius(DshDesign.radiusCompact)
          .constraintSize({ maxHeight: 196 })
          .align(Alignment.TopStart)
          .scrollBar(BarState.Auto)
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    if (this.steps.length > 0) {
      Column({ space: this.expanded ? 3 : 0 }) {
        // 移植自 DSH-Harmony NativeProcessView.ets 顶层无框扁平行
        Button({ type: ButtonType.Normal }) {
          Row({ space: 5 }) {
            DshIcon({
              glyph: 'think-outline',
              glyphSize: DshDesign.glyphCompact,
              color: this.isLive ? DshDesign.deepDiving(this.dark()) : DshDesign.textTertiary(this.dark())
            })
            Text('工作过程')
              .fontSize(DshDesign.fontSection)
              .fontWeight(FontWeight.Medium)
              .fontColor(DshDesign.textSecondary(this.dark()))
            Text('·')
              .fontSize(DshDesign.fontSection)
              .fontColor(DshDesign.textTertiary(this.dark()))
            Text(summarizeProcessSteps(this.steps, this.isLive))
              .fontSize(DshDesign.fontSection)
              .fontColor(this.isLive ? DshDesign.deepDiving(this.dark()) : DshDesign.textTertiary(this.dark()))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            DshIcon({
              glyph: this.expanded ? 'chevron-up' : 'chevron-down',
              glyphSize: DshDesign.glyphInline,
              color: DshDesign.textTertiary(this.dark())
            })
          }.width('100%').alignItems(VerticalAlign.Center)
        }
        .height(DshDesign.compactControl)
        .width('100%')
        .padding({ left: 2, right: 2 })
        .backgroundColor(Color.Transparent)
        .accessibilityText(this.expanded ? '收起工作过程' : '展开工作过程')
        .onClick((): void => { this.expanded = !this.expanded; })

        if (this.expanded) {
          Column({ space: 2 }) {
            ForEach(
              this.steps,
              (step: AiProcessStep, idx: number) => {
                if (step.kind === 'tool' && step.tool !== undefined) {
                  this.renderToolStep(step, step.tool, idx === this.steps.length - 1)
                } else if (step.kind === 'thinking') {
                  this.renderThinkingStep(step, idx === this.steps.length - 1)
                } else if (step.kind === 'commentary' && step.text.trim().length > 0) {
                  Text(step.text)
                    .fontSize(DshDesign.fontSection)
                    .lineHeight(18)
                    .fontColor(DshDesign.textTertiary(this.dark()))
                    .padding({ left: 22, right: 4, top: 2, bottom: 2 })
                    .width('100%')
                }
              },
              (step: AiProcessStep): string => `${this.turnKey}:${step.id}:${step.status}:${step.tool?.status ?? ''}:${step.tool?.result.length ?? 0}`
            )
          }
          .width('100%')
          .padding({ left: 6, bottom: 4 })
          .border({ width: { left: 1.5 }, color: DshDesign.divider(this.dark()) })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 4 })
    }
  }
}

export function extractLatestPlanFromSteps(steps: AiProcessStep[]): AiPlanStepView[] {
  const tools: AiChatToolState[] = [];
  for (let i = 0; i < steps.length; i++) {
    const t: AiChatToolState | undefined = steps[i].tool;
    if (steps[i].kind === 'tool' && t !== undefined) {
      tools.push(t);
    }
  }
  return extractAiPlan(tools);
}


/**
 * 鸿蒙原生交互式提问卡（Agent 调用 `ask_user` 时挂起工具循环并原地收集用户单选/多选/补充说明）
 */
@Component
export struct DshAskUserCard {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  private dark(): boolean { return this.effectiveIsDark || DshDesign.isDark(); }
  @Prop @Watch('onRequestChanged') request: AiAskUserRequest = {
    id: '',
    question: '',
    options: [],
    multiSelect: false,
    allowCustomInput: true
  };
  onSubmit: (exchange: AiAskUserExchange) => void = (_ex: AiAskUserExchange): void => {};

  @State private selectedLabels: string[] = [];
  @State private customInput: string = '';

  aboutToAppear(): void {
    this.onRequestChanged();
  }

  onRequestChanged(): void {
    this.selectedLabels = this.request.options.length > 0 && !this.request.multiSelect
      ? [this.request.options[0].label]
      : [];
    this.customInput = '';
  }

  private isSelected(label: string): boolean {
    return this.selectedLabels.includes(label);
  }

  private toggleOption(label: string): void {
    if (this.request.multiSelect) {
      if (this.selectedLabels.includes(label)) {
        this.selectedLabels = this.selectedLabels.filter((x: string): boolean => x !== label);
      } else {
        this.selectedLabels = this.selectedLabels.concat([label]);
      }
    } else {
      this.selectedLabels = [label];
    }
  }

  private cleanQuestionText(): string {
    return (this.request.question || '')
      .replace(/[（(]\s*(?:可多选|多选|单选)\s*[）)]\s*([？?:：]?)$/u, '$1')
      .trim();
  }

  private canConfirm(): boolean {
    return this.selectedLabels.length > 0 || this.customInput.trim().length > 0;
  }

  private commit(skipped: boolean): void {
    const exchange: AiAskUserExchange = {
      id: this.request.id,
      question: this.request.question,
      context: this.request.context,
      options: this.request.options,
      multiSelect: this.request.multiSelect,
      selectedLabels: skipped ? [] : this.selectedLabels.slice(),
      customText: skipped ? '' : this.customInput.trim(),
      skipped: skipped
    };
    this.onSubmit(exchange);
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        DshIcon({
          glyph: 'ask-outline',
          glyphSize: 15,
          color: DshDesign.accent(this.dark())
        })
        Text('Agent 需要你的确认')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(DshDesign.accent(this.dark()))
          .layoutWeight(1)
        Text(this.request.multiSelect ? '可多选' : '单选')
          .fontSize(10)
          .fontColor(DshDesign.textTertiary(this.dark()))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(DshDesign.field(this.dark()))
          .borderRadius(999)
      }.width('100%').alignItems(VerticalAlign.Center)

      Text(this.cleanQuestionText())
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(DshDesign.textPrimary(this.dark()))
        .lineHeight(19)
        .width('100%')

      if (this.request.context !== undefined && this.request.context.trim().length > 0) {
        Text(this.request.context)
          .fontSize(11.5)
          .fontColor(DshDesign.textSecondary(this.dark()))
          .lineHeight(17)
          .width('100%')
      }

      if (this.request.options.length > 0) {
        Column({ space: 5 }) {
          ForEach(this.request.options, (opt: AiAskUserOption, idx: number) => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 8 }) {
                if (this.request.multiSelect) {
                  Checkbox({ name: `ask_chk_${idx}`, group: `ask_grp_${this.request.id}` })
                    .shape(CheckBoxShape.ROUNDED_SQUARE)
                    .select(this.isSelected(opt.label))
                    .selectedColor(COLORS.primary)
                    .width(16)
                    .height(16)
                    .hitTestBehavior(HitTestMode.None)
                } else {
                  Radio({ value: opt.label, group: `ask_rad_${this.request.id}` })
                    .checked(this.isSelected(opt.label))
                    .width(16)
                    .height(16)
                    .hitTestBehavior(HitTestMode.None)
                }
                Column({ space: 2 }) {
                  Text(opt.label)
                    .fontSize(12.5)
                    .fontWeight(this.isSelected(opt.label) ? FontWeight.Medium : FontWeight.Regular)
                    .fontColor(DshDesign.textPrimary(this.dark()))
                    .width('100%')
                    .textAlign(TextAlign.Start)
                  if (opt.description !== undefined && opt.description.trim().length > 0) {
                    Text(opt.description)
                      .fontSize(11)
                      .fontColor(DshDesign.textTertiary(this.dark()))
                      .width('100%')
                      .textAlign(TextAlign.Start)
                      .maxLines(2)
                  }
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.width('100%').alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 7, bottom: 7 })
            .backgroundColor(this.isSelected(opt.label) ? DshDesign.selectedSurface(this.dark()) : DshDesign.field(this.dark()))
            .border({
              width: 0.8,
              color: this.isSelected(opt.label) ? COLORS.primary : DshDesign.border(this.dark())
            })
            .borderRadius(8)
            .onClick((): void => {
              this.toggleOption(opt.label);
            })
          }, (opt: AiAskUserOption, idx: number): string => `${this.request.id}_${idx}_${opt.label}_${this.selectedLabels.join('|')}`)
        }.width('100%')
      }

      if (this.request.allowCustomInput) {
        TextInput({
          text: this.customInput,
          placeholder: this.request.placeholder && this.request.placeholder.length > 0
            ? this.request.placeholder
            : '补充自定义参数或直接输入说明（选填）…'
        })
          .width('100%')
          .height(34)
          .fontSize(12)
          .fontColor(DshDesign.textPrimary(this.dark()))
          .placeholderColor(DshDesign.textTertiary(this.dark()))
          .backgroundColor(DshDesign.field(this.dark()))
          .border({ width: 0.8, color: DshDesign.border(this.dark()) })
          .borderRadius(8)
          .onKeyEvent((e: KeyEvent) => { e.stopPropagation(); })
          .onChange((v: string) => { this.customInput = v; })
          .onSubmit(() => {
            if (this.canConfirm()) {
              this.commit(false);
            }
          })
      }

      Row({ space: 8 }) {
        Blank()
        Button('跳过由 Agent 决定', { type: ButtonType.Capsule })
          .height(30)
          .padding({ left: 12, right: 12 })
          .fontSize(11.5)
          .fontColor(DshDesign.textSecondary(this.dark()))
          .backgroundColor(DshDesign.field(this.dark()))
          .onClick((): void => { this.commit(true); })
        Button('确认并继续', { type: ButtonType.Capsule })
          .height(30)
          .padding({ left: 14, right: 14 })
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(COLORS.primary)
          .enabled(this.canConfirm())
          .onClick((): void => { this.commit(false); })
      }.width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor(DshDesign.raised(this.dark()))
    .border({ width: 1, color: COLORS.primary })
    .borderRadius(12)
  }
}

/**
 * 消息气泡多模态附件网格：支持图片缩略图预览、一键复制图片/文件至系统剪贴板、另存为及一键在画布打开版图
 */
@Component
export struct DshAttachmentGrid {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  private dark(): boolean { return this.effectiveIsDark || DshDesign.isDark(); }
  @Prop attachments: AiChatAttachment[] = [];
  @Prop alignEnd: boolean = false;
  onCopy: (att: AiChatAttachment) => void = (_att: AiChatAttachment): void => {};
  onSaveAs: (att: AiChatAttachment) => void = (_att: AiChatAttachment): void => {};
  onOpenLayout: (att: AiChatAttachment) => void = (_att: AiChatAttachment): void => {};

  private imageSource(att: AiChatAttachment): string {
    if (att.sandboxPath.length > 0) {
      return att.sandboxPath.startsWith('file://') ? att.sandboxPath : `file://${att.sandboxPath}`;
    }
    return att.fileUriString;
  }

  build() {
    if (this.attachments.length > 0) {
      Column({ space: 6 }) {
        ForEach(this.attachments, (att: AiChatAttachment) => {
          Column({ space: 6 }) {
            if (att.kind === 'image') {
              Image(this.imageSource(att))
                .width('100%')
                .constraintSize({ maxHeight: 196 })
                .objectFit(ImageFit.Contain)
                .backgroundColor(DshDesign.field(this.dark()))
                .borderRadius(8)
            }

            Row({ space: 6 }) {
              SymbolGlyph(
                att.kind === 'image'
                  ? $r('sys.symbol.rectangle_on_rectangle')
                  : (att.kind === 'layout' ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.doc_text'))
              )
                .fontSize(14)
                .fontColor([COLORS.primary])
              Column({ space: 1 }) {
                Text(att.name)
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(DshDesign.textPrimary(this.dark()))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${att.kind === 'image' ? (att.width && att.height ? `${att.width}×${att.height} · ` : '') : ''}${formatAttachmentSize(att.sizeBytes)}`)
                  .fontSize(10)
                  .fontColor(DshDesign.textTertiary(this.dark()))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').alignItems(VerticalAlign.Center)

            Row({ space: 6 }) {
              Button(att.kind === 'image' ? '复制图片' : '复制文件', { type: ButtonType.Normal })
                .height(24)
                .padding({ left: 8, right: 8 })
                .fontSize(10.5)
                .fontColor(COLORS.primary)
                .backgroundColor(COLORS.primarySoft)
                .borderRadius(6)
                .onClick((): void => { this.onCopy(att); })

              Button('另存为', { type: ButtonType.Normal })
                .height(24)
                .padding({ left: 8, right: 8 })
                .fontSize(10.5)
                .fontColor(DshDesign.textPrimary(this.dark()))
                .backgroundColor(DshDesign.field(this.dark()))
                .borderRadius(6)
                .onClick((): void => { this.onSaveAs(att); })

              if (att.kind === 'layout') {
                Button('在画布打开', { type: ButtonType.Normal })
                  .height(24)
                  .padding({ left: 8, right: 8 })
                  .fontSize(10.5)
                  .fontColor(Color.White)
                  .backgroundColor(COLORS.primary)
                  .borderRadius(6)
                  .onClick((): void => { this.onOpenLayout(att); })
              }
            }.width('100%').alignItems(VerticalAlign.Center)
          }
          .width(this.alignEnd ? '86%' : '100%')
          .padding(8)
          .backgroundColor(DshDesign.subtleSurface(this.dark()))
          .border({ width: 0.8, color: DshDesign.border(this.dark()) })
          .borderRadius(10)
        }, (att: AiChatAttachment): string => `${att.id}:${att.name}:${att.sizeBytes}`)
      }
      .width('100%')
      .alignItems(this.alignEnd ? HorizontalAlign.End : HorizontalAlign.Start)
      .margin({ top: 4, bottom: 2 })
    }
  }
}

/**
 * 网页检索引用来源原生 Chip 条（点击复制来源链接并在状态提示中展示）
 */
@Component
export struct DshWebSourcesRow {
  @Prop sources: DshWebSearchItem[] = [];
  onSelectSource: (item: DshWebSearchItem) => void = (_item: DshWebSearchItem): void => {};

  build() {
    if (this.sources.length > 0) {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.sources, (src: DshWebSearchItem, idx: number) => {
          Row() {
            Chip({
              prefixSymbol: {
                normal: new SymbolGlyphModifier($r('sys.symbol.square_link_square')).fontSize(12).fontColor([COLORS.primary]),
                activated: new SymbolGlyphModifier($r('sys.symbol.square_link_square')).fontSize(12).fontColor([COLORS.primary])
              },
              label: {
                text: src.title.length > 24 ? `${src.title.substring(0, 23)}…` : src.title,
                fontSize: 11,
                fontColor: COLORS.ink
              },
              size: ChipSize.SMALL,
              allowClose: false,
              backgroundColor: COLORS.surfaceMuted,
              borderRadius: UI.controlRadius,
              onClicked: () => {
                this.onSelectSource(src);
              }
            })
          }.margin({ right: 6, bottom: 6 })
        }, (src: DshWebSearchItem, idx: number): string => `${idx}:${src.url}`)
      }
      .width('100%')
      .margin({ top: 4, bottom: 2 })
    }
  }
}
