/**
 * 鸿图图纸舞台 Agent 两期光感特效与全态势运行胶囊（AgentCanvasStageOverlay）
 *
 * 满足版图工程师边看全屏图纸边观测 Agent 作业的核心体验：
 * 1. `AgentCanvasAuraOverlay`（挂载于图纸视口内层 Stack，100% 穿透手势 `HitTestMode.None`）：
 *    - 第一期（实时操作/绘图中 `isLoading === true`）：全画布四边流光扫描外框 + 四边向内极光柔晕 + 顶部流式扫描光束 + 四角精密取景准星；
 *    - 第二期（待确认几何预览 `pendingActive === true`）：全画布稳态青绿双色预览光框 + 四边轻柔内晕 + 四角几何锚定角标，明确标识画布处于未落盘预览态。
 * 2. `AgentLiveStatusHud`（挂载于工作台顶层浮窗区，无论 AI 窗口收起或放下均清晰可见）：
 *    - 实时展示运行计时（MM:SS）、当前执行步数、工具语义目标（如 `查询版图明细 · L4/0` / `生成 CMOS 反相器`）；
 *    - 支持一键「收起窗口 / 展开窗口」、运行中直接「停止」、待确认态直接「定位 / 应用 / 取消」以及后台完成提醒。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { COLORS } from '../../common/constants';
import { REDUCE_MOTION_KEY } from '../../common/Motion';
import { RADIUS, withAlpha } from '../../common/MaterialTokens';
import { UI } from '../../common/UiTokens';
import { hongTuThemeState, Radius } from '../../store/ThemeStore';
import type { AiChatToolState } from '../../services/AiService';
import {
  AgentCanvasHudModel,
  AiLiveStreamSnapshot,
  buildAgentCanvasHudModel,
  getAiLiveStreamSnapshot
} from '../../services/AiAgentPresentation';
import type { AiProcessStep } from '../../services/AiService';
import { DrawnStatusIcon } from '../DrawnStatusIcon';
import { WorkbenchIcon } from './WorkbenchIcon';

@Component
export struct AgentCanvasAuraOverlay {
  @Prop @Watch('onPhaseChanged') isLoading: boolean = false;
  @Prop @Watch('onPhaseChanged') pendingActive: boolean = false;
  @StorageProp(REDUCE_MOTION_KEY) @Watch('onPhaseChanged') reduceMotion: boolean = false;
  @State sweepStep: number = 0;
  @State pulseTick: boolean = false;
  private auraTimer: number = -1;
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.disposed = false;
    this.syncTimer();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.stopTimer();
  }

  onPhaseChanged(): void {
    if (this.disposed) {
      return;
    }
    this.syncTimer();
  }

  private stopTimer(): void {
    if (this.auraTimer >= 0) {
      clearInterval(this.auraTimer);
      this.auraTimer = -1;
    }
  }

  private syncTimer(): void {
    if (!this.isLoading || this.reduceMotion) {
      this.stopTimer();
      this.sweepStep = 0;
      this.pulseTick = false;
      return;
    }
    if (this.auraTimer >= 0) {
      return;
    }
    this.auraTimer = setInterval((): void => {
      if (this.disposed || !this.isLoading || this.reduceMotion) {
        this.stopTimer();
        return;
      }
      this.sweepStep = (this.sweepStep + 1) % 30;
      if (this.sweepStep % 8 === 0) {
        this.pulseTick = !this.pulseTick;
      }
    }, 80);
  }

  private activeBorderColor(): string {
    if (!this.isLoading) {
      return withAlpha('#14B8A6', 0.85);
    }
    if (this.reduceMotion) {
      return '#0A73F6';
    }
    if (this.sweepStep < 10) {
      return '#0A73F6';
    }
    if (this.sweepStep < 20) {
      return '#16C8C7';
    }
    return '#5E6AD2';
  }

  @Builder
  private CornerReticle(isTop: boolean, isLeft: boolean, strokeColor: string) {
    Column()
      .width(22)
      .height(22)
      .border({
        width: {
          top: isTop ? 2.5 : 0,
          bottom: isTop ? 0 : 2.5,
          left: isLeft ? 2.5 : 0,
          right: isLeft ? 0 : 2.5
        },
        color: strokeColor
      })
      .hitTestBehavior(HitTestMode.None)
  }

  build() {
    if (this.isLoading || this.pendingActive) {
      Stack() {
        // 1. 上下边缘向内极光渐变柔晕
        Column() {
          Column()
            .width('100%')
            .height(this.isLoading ? 28 : 18)
            .linearGradient({
              direction: GradientDirection.Bottom,
              colors: this.isLoading
                ? [[withAlpha('#0A73F6', this.pulseTick ? 0.25 : 0.16), 0.0], ['rgba(10, 115, 246, 0)', 1.0]]
                : [[withAlpha('#14B8A6', 0.16), 0.0], ['rgba(20, 184, 166, 0)', 1.0]]
            })
            .hitTestBehavior(HitTestMode.None)
          Blank()
          Column()
            .width('100%')
            .height(this.isLoading ? 26 : 16)
            .linearGradient({
              direction: GradientDirection.Top,
              colors: this.isLoading
                ? [[withAlpha('#16C8C7', this.pulseTick ? 0.22 : 0.14), 0.0], ['rgba(22, 200, 199, 0)', 1.0]]
                : [[withAlpha('#0A73F6', 0.14), 0.0], ['rgba(10, 115, 246, 0)', 1.0]]
            })
            .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)

        // 2. 左右边缘向内极光渐变柔晕
        Row() {
          Row()
            .width(this.isLoading ? 24 : 14)
            .height('100%')
            .linearGradient({
              direction: GradientDirection.Right,
              colors: this.isLoading
                ? [[withAlpha('#0A73F6', this.pulseTick ? 0.20 : 0.13), 0.0], ['rgba(10, 115, 246, 0)', 1.0]]
                : [[withAlpha('#14B8A6', 0.14), 0.0], ['rgba(20, 184, 166, 0)', 1.0]]
            })
            .hitTestBehavior(HitTestMode.None)
          Blank()
          Row()
            .width(this.isLoading ? 24 : 14)
            .height('100%')
            .linearGradient({
              direction: GradientDirection.Left,
              colors: this.isLoading
                ? [[withAlpha('#5E6AD2', this.pulseTick ? 0.20 : 0.13), 0.0], ['rgba(94, 106, 210, 0)', 1.0]]
                : [[withAlpha('#0A73F6', 0.14), 0.0], ['rgba(10, 115, 246, 0)', 1.0]]
            })
            .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)

        // 3. 第一期顶部流光扫描进度光束（直观呈现 Agent 正在读写/绘制版图）
        if (this.isLoading) {
          Column() {
            Progress({ value: 100, total: 100, type: ProgressType.Linear })
              .color('#16C8C7')
              .backgroundColor(withAlpha('#0A73F6', 0.20))
              .style({ strokeWidth: 3, enableScanEffect: !this.reduceMotion })
              .width('100%')
              .hitTestBehavior(HitTestMode.None)
            Blank()
          }
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
        }

        // 4. 全画布外轮廓光效框（第一期动态流光边框 / 第二期稳态预览边框）
        Column()
          .width('100%')
          .height('100%')
          .border({
            width: this.isLoading ? 2.2 : 1.8,
            color: this.activeBorderColor()
          })
          .hitTestBehavior(HitTestMode.None)

        // 5. 四角精密光感准星角标
        Column() {
          Row() {
            this.CornerReticle(true, true, this.isLoading ? '#16C8C7' : '#14B8A6')
            Blank()
            this.CornerReticle(true, false, this.isLoading ? '#0A73F6' : '#14B8A6')
          }.width('100%')
          Blank()
          Row() {
            this.CornerReticle(false, true, this.isLoading ? '#0A73F6' : '#14B8A6')
            Blank()
            this.CornerReticle(false, false, this.isLoading ? '#5E6AD2' : '#14B8A6')
          }.width('100%')
        }
        .width('100%')
        .height('100%')
        .padding(6)
        .hitTestBehavior(HitTestMode.None)
      }
      .id('agent-canvas-aura-overlay')
      .width('100%')
      .height('100%')
      .clip(true)
      .hitTestBehavior(HitTestMode.None)
    }
  }
}

@Component
export struct AgentLiveStatusHud {
  @Prop @Watch('onStateChanged') isLoading: boolean = false;
  @Prop @Watch('onStateChanged') waitingForUser: boolean = false;
  @Prop canCancel: boolean = false;
  @Prop @Watch('onStateChanged') pendingSummary: string = '';
  @Prop @Watch('onStateChanged') minimizedNotice: string = '';
  @Prop showAiPanel: boolean = false;
  @Prop toolCalls: AiChatToolState[] = [];
  @Prop generationStatus: string = '';
  @Prop streamingText: string = '';
  @Prop @Watch('onStateChanged') runStartedAt: number = 0;
  @Prop hudWidth: number = 420;
  togglePanelAction: () => void = () => {};
  stopAction: () => void = () => {};
  focusPreviewAction: () => void = () => {};
  applyPreviewAction: () => void = () => {};
  cancelPreviewAction: () => void = () => {};
  dismissNoticeAction: () => void = () => {};

  @StorageLink('hongtu_ai_live_rev') @Watch('onLiveStreamTick') liveStreamRev: number = 0;
  @State liveRunning: boolean = false;
  @State liveStatusText: string = '';
  @State liveAnswerText: string = '';
  @State liveTools: AiChatToolState[] = [];
  @State nowMs: number = Date.now();
  private clockTimer: number = -1;
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.disposed = false;
    this.onLiveStreamTick();
    this.syncClock();
  }

  onLiveStreamTick(): void {
    if (this.disposed) return;
    const snap: AiLiveStreamSnapshot = getAiLiveStreamSnapshot();
    this.liveRunning = snap.running;
    this.liveStatusText = snap.statusText;
    this.liveAnswerText = snap.answerText.length > 0 ? snap.answerText : snap.activeThinkText;
    const tools: AiChatToolState[] = [];
    for (let i = 0; i < snap.steps.length; i++) {
      const s: AiProcessStep = snap.steps[i];
      if (s.kind === 'tool' && s.tool !== undefined) {
        tools.push(s.tool);
      }
    }
    this.liveTools = tools;
    this.nowMs = Date.now();
    this.syncClock();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.stopClock();
  }

  onStateChanged(): void {
    if (this.disposed) {
      return;
    }
    this.nowMs = Date.now();
    this.syncClock();
  }

  private stopClock(): void {
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
  }

  private syncClock(): void {
    if (!this.isLoading && !this.liveRunning) {
      this.stopClock();
      return;
    }
    if (this.clockTimer >= 0) {
      return;
    }
    this.clockTimer = setInterval((): void => {
      if (this.disposed || !this.isLoading) {
        this.stopClock();
        return;
      }
      this.nowMs = Date.now();
    }, 1000);
  }

  private hudModel(): AgentCanvasHudModel {
    const activeLoading: boolean = this.liveRunning || this.isLoading;
    const activeTools: AiChatToolState[] = this.liveTools.length > 0 ? this.liveTools : this.toolCalls;
    const activeStatus: string = this.liveStatusText.length > 0 ? this.liveStatusText : this.generationStatus;
    const activeText: string = this.liveAnswerText.length > 0 ? this.liveAnswerText : this.streamingText;
    return buildAgentCanvasHudModel(
      activeLoading,
      this.pendingSummary,
      this.minimizedNotice,
      this.showAiPanel,
      activeTools,
      activeStatus,
      activeText,
      this.runStartedAt,
      this.nowMs,
      this.waitingForUser
    );
  }

  build() {
    if (this.hudModel().phase !== 'hidden') {
      Row({ space: 10 }) {
        if (this.hudModel().phase === 'drawing') {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(COLORS.primary)
        } else {
          DrawnStatusIcon({
            kind: (this.hudModel().phase === 'preview' || this.hudModel().phase === 'waiting') ? 'active' : 'success',
            iconSize: 18,
            strokeColor: (this.hudModel().phase === 'preview' || this.hudModel().phase === 'waiting') ? '#14B8A6' : COLORS.success,
            showSoftPlate: true
          })
        }

        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(this.hudModel().title)
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.ink)
              .maxLines(1)
            Text(this.hudModel().badge)
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.hudModel().phase === 'drawing' ? COLORS.primary : '#0D9488')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor(this.hudModel().phase === 'drawing' ? COLORS.primarySoft : withAlpha('#14B8A6', 0.15))
              .borderRadius(RADIUS.capsule)
            if (this.hudModel().stepText.length > 0) {
              Text(this.hudModel().stepText)
                .fontSize(10)
                .fontColor(COLORS.muted)
            }
            if (this.hudModel().elapsedText.length > 0) {
              Text(this.hudModel().elapsedText)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor(COLORS.primary)
            }
          }.alignItems(VerticalAlign.Center)

          Text(this.hudModel().detail)
            .fontSize(11)
            .fontColor(COLORS.muted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row({ space: 6 }) {
          if (this.hudModel().phase === 'drawing' && this.canCancel) {
            Button('停止', { type: ButtonType.Normal })
              .height(28)
              .padding({ left: 10, right: 10 })
              .fontSize(11)
              .fontColor(COLORS.danger)
              .backgroundColor(COLORS.dangerSoft)
              .borderRadius(RADIUS.capsule)
              .onClick(() => this.stopAction())
          }
          if (this.hudModel().phase === 'preview' && !this.showAiPanel) {
            Button('定位', { type: ButtonType.Normal })
              .height(28)
              .padding({ left: 9, right: 9 })
              .fontSize(11)
              .fontColor(COLORS.ink)
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(RADIUS.capsule)
              .onClick(() => this.focusPreviewAction())
            Button('取消', { type: ButtonType.Normal })
              .height(28)
              .padding({ left: 9, right: 9 })
              .fontSize(11)
              .fontColor(COLORS.ink)
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(RADIUS.capsule)
              .onClick(() => this.cancelPreviewAction())
            Button('应用', { type: ButtonType.Normal })
              .height(28)
              .padding({ left: 11, right: 11 })
              .fontSize(11)
              .fontColor(Color.White)
              .backgroundColor(COLORS.primary)
              .borderRadius(RADIUS.capsule)
              .onClick(() => this.applyPreviewAction())
          }
          Button(this.showAiPanel ? '收起窗口' : '展开窗口', { type: ButtonType.Normal })
            .id('agent-hud-toggle-window-btn')
            .height(28)
            .padding({ left: 10, right: 10 })
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.showAiPanel ? COLORS.ink : COLORS.primary)
            .backgroundColor(this.showAiPanel ? COLORS.surfaceMuted : COLORS.primarySoft)
            .borderRadius(RADIUS.capsule)
            .onClick(() => this.togglePanelAction())

          if (this.hudModel().phase === 'completed') {
            Button({ type: ButtonType.Normal }) {
              WorkbenchIcon({ name: 'close', iconSize: 13, color: COLORS.muted })
            }
            .width(24)
            .height(24)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .borderRadius(UI.controlRadius)
            .accessibilityText('关闭完成提示')
            .onClick(() => this.dismissNoticeAction())
          }
        }.alignItems(VerticalAlign.Center)
      }
      .id('agent-live-status-hud')
      .width(this.hudWidth)
      .padding({ left: 14, right: 12, top: 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)
      .border({
        width: 1,
        color: this.hudModel().phase === 'drawing'
          ? withAlpha(COLORS.primary, 0.45)
          : withAlpha('#14B8A6', 0.45)
      })
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(Radius.pill, 'thick', hongTuThemeState.elevation('lg')))
    }
  }
}
