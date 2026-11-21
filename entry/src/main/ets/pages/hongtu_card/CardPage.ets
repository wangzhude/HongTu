/**
 * 鸿图光感自适应桌面服务卡片（支持 2*2 紧凑概览与 2*4 双栏工作台快捷动作）
 *
 * 设计约束：
 * 1. 运行于系统桌面卡片宿主沙箱，严禁引入主进程 UIMaterial / UIDesignKit 单例；
 * 2. 全量色彩绑定 base/dark 双目录 `$r('app.color.*')` 语义 Token，随系统深浅色无缝切换；
 * 3. 零 Emoji 纯矢量视觉：采用抗锯齿 Canvas 绘制晶圆光刻准星徽标，搭配系统 SymbolGlyph；
 * 4. 遵守 `@Builder` 响应式规则，统一通过单对象字面量或无参成员访问触发重绘。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

let storage = new LocalStorage();

interface CardVisualState {
  fileName: string;
  fileType: string;
  fileSize: number;
  drcErrors: number;
  drcWarnings: number;
  drcPassed: boolean;
  drcChecked: boolean;
  drcIncomplete: boolean;
  drcScope: string;
  updateTime: string;
}

@Entry(storage)
@Component
struct CardPage {
  @LocalStorageProp('documentId') documentId: string = '';
  @LocalStorageProp('fileName') fileName: string = '尚未打开文件';
  @LocalStorageProp('fileType') fileType: string = '版图';
  @LocalStorageProp('fileSize') fileSize: number = 0;
  @LocalStorageProp('drcErrors') drcErrors: number = 0;
  @LocalStorageProp('drcWarnings') drcWarnings: number = 0;
  @LocalStorageProp('drcPassed') drcPassed: boolean = false;
  @LocalStorageProp('drcChecked') drcChecked: boolean = false;
  @LocalStorageProp('drcIncomplete') drcIncomplete: boolean = false;
  @LocalStorageProp('drcScope') drcScope: string = '';
  @LocalStorageProp('updateTime') updateTime: string = '';
  @LocalStorageProp('formDimension') formDimension: number = 2;

  private waferCanvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private waferCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.waferCanvasSettings);

  private snapshotState(): CardVisualState {
    return {
      fileName: this.fileName,
      fileType: this.fileType,
      fileSize: this.fileSize,
      drcErrors: this.drcErrors,
      drcWarnings: this.drcWarnings,
      drcPassed: this.drcPassed,
      drcChecked: this.drcChecked,
      drcIncomplete: this.drcIncomplete,
      drcScope: this.drcScope,
      updateTime: this.updateTime,
    };
  }

  private hasActiveLayout(state: CardVisualState): boolean {
    return state.fileSize > 0 && state.fileName !== '尚未打开文件';
  }

  private statusLabel(state: CardVisualState): string {
    if (!state.drcChecked) {
      return 'DRC 待检查';
    }
    if (state.drcIncomplete) {
      return 'DRC 检查不完整';
    }
    if (!state.drcPassed) {
      return `DRC ${state.drcErrors} 项错误`;
    }
    return state.drcWarnings > 0 ? `DRC 通过 · ${state.drcWarnings} 警告` : 'DRC 全部通过';
  }

  private statusDotColor(state: CardVisualState): ResourceColor {
    if (!state.drcChecked) {
      return $r('app.color.muted');
    }
    if (state.drcIncomplete) {
      return $r('app.color.warning');
    }
    if (!state.drcPassed) {
      return $r('app.color.danger');
    }
    return state.drcWarnings > 0 ? $r('app.color.warning') : $r('app.color.success');
  }

  private statusPillBg(state: CardVisualState): ResourceColor {
    if (!state.drcChecked) {
      return $r('app.color.neutral_soft');
    }
    if (state.drcIncomplete) {
      return $r('app.color.warning_soft');
    }
    if (!state.drcPassed) {
      return $r('app.color.danger_soft');
    }
    return state.drcWarnings > 0 ? $r('app.color.warning_soft') : $r('app.color.success_soft');
  }

  private sizeAndTimeLabel(state: CardVisualState): string {
    if (state.fileSize <= 0) {
      return '拖入或选择 GDSII / OASIS 版图';
    }
    const sizeText: string = state.fileSize >= 1048576
      ? `${(state.fileSize / 1048576).toFixed(1)} MB`
      : `${(state.fileSize / 1024).toFixed(1)} KB`;
    return state.updateTime.length > 0 ? `${sizeText} · ${state.updateTime}` : sizeText;
  }

  private drawWaferEmblem(): void {
    const ctx: CanvasRenderingContext2D = this.waferCtx;
    const w: number = 28;
    const h: number = 28;
    ctx.clearRect(0, 0, w, h);
    ctx.strokeStyle = '#FFFFFF';
    ctx.lineWidth = 1.5;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    // 晶圆外环与定位切口
    ctx.beginPath();
    ctx.arc(14, 14, 9.5, 0.22 * Math.PI, 0.78 * Math.PI, true);
    ctx.stroke();
    // 内部版图十字光刻准星与 Die 晶粒框
    ctx.strokeRect(10, 10, 8, 8);
    ctx.beginPath();
    ctx.moveTo(14, 5.5);
    ctx.lineTo(14, 9);
    ctx.moveTo(14, 19);
    ctx.lineTo(14, 22.5);
    ctx.moveTo(5.5, 14);
    ctx.lineTo(9, 14);
    ctx.moveTo(19, 14);
    ctx.lineTo(22.5, 14);
    ctx.stroke();
  }

  private triggerRouterCommand(cardCommand: string): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        cardCommand: cardCommand,
        documentId: this.documentId,
      }
    });
  }

  private triggerSnapshotRefresh(): void {
    postCardAction(this, {
      action: 'message',
      params: {
        command: 'refresh',
      }
    });
  }

  @Builder
  private buildCardHeader(state: CardVisualState) {
    Row({ space: 8 }) {
      Stack() {
        Canvas(this.waferCtx)
          .width(28)
          .height(28)
          .onReady(() => {
            this.drawWaferEmblem();
          })
      }
      .width(30)
      .height(30)
      .borderRadius(9)
      .linearGradient({
        angle: 135,
        colors: [['#0A59F7', 0.0], ['#2B86FF', 1.0]]
      })

      Column({ space: 1 }) {
        Text('鸿图')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
          .maxLines(1)
        Text('HongTu EDA')
          .fontSize(9)
          .fontColor($r('app.color.muted'))
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Text(state.fileType.length > 0 ? state.fileType : '版图')
        .fontSize(10)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary'))
        .backgroundColor($r('app.color.primary_soft'))
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
        .borderRadius(999)

      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(13)
          .fontColor([$r('app.color.muted')])
      }
      .width(24)
      .height(24)
      .backgroundColor($r('app.color.surface_muted'))
      .accessibilityText('刷新版图卡片状态')
      .onClick(() => {
        this.triggerSnapshotRefresh();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private buildStatusBadge(state: CardVisualState) {
    Row({ space: 6 }) {
      Circle()
        .width(7)
        .height(7)
        .fill(this.statusDotColor(state))
      Text(this.statusLabel(state))
        .fontSize(11)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.ink'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 9, right: 9, top: 6, bottom: 6 })
    .borderRadius(9)
    .backgroundColor(this.statusPillBg(state))
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private buildCompact2x2(state: CardVisualState) {
    Column() {
      this.buildCardHeader(state)

      Column({ space: 3 }) {
        Text(state.fileName)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.ink'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.sizeAndTimeLabel(state))
          .fontSize(10)
          .fontColor($r('app.color.muted'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .layoutWeight(1)

      this.buildStatusBadge(state)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .onClick(() => {
      this.triggerRouterCommand(this.hasActiveLayout(state) ? 'resume' : 'openPicker');
    })
  }

  @Builder
  private buildWide2x4(state: CardVisualState) {
    Column({ space: 8 }) {
      this.buildCardHeader(state)

      Row({ space: 10 }) {
        Column({ space: 6 }) {
          Column({ space: 2 }) {
            Text(state.fileName)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.ink'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.sizeAndTimeLabel(state))
              .fontSize(10)
              .fontColor($r('app.color.muted'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          this.buildStatusBadge(state)

          if (state.drcScope.length > 0) {
            Text(state.drcScope)
              .fontSize(9)
              .fontColor($r('app.color.muted'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .padding(10)
        .borderRadius(12)
        .backgroundColor($r('app.color.card_inner_card'))
        .border({ width: 0.6, color: $r('app.color.border') })
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.SpaceBetween)
        .height('100%')
        .onClick(() => {
          this.triggerRouterCommand('resume');
        })

        Column({ space: 8 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.arrow_right_up_and_square'))
                .fontSize(13)
                .fontColor(['#FFFFFF'])
              Text('进入工作台')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFF')
            }
            .alignItems(VerticalAlign.Center)
          }
          .width(106)
          .layoutWeight(1)
          .borderRadius(10)
          .linearGradient({
            angle: 135,
            colors: [['#0A59F7', 0.0], ['#2984FF', 1.0]]
          })
          .onClick(() => {
            this.triggerRouterCommand('resume');
          })

          Button({ type: ButtonType.Normal }) {
            Row({ space: 4 }) {
              SymbolGlyph(this.hasActiveLayout(state) ? $r('sys.symbol.checkmark_shield') : $r('sys.symbol.folder'))
                .fontSize(13)
                .fontColor([$r('app.color.primary')])
              Text(this.hasActiveLayout(state) ? '运行 DRC' : '打开版图')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.primary'))
            }
            .alignItems(VerticalAlign.Center)
          }
          .width(106)
          .layoutWeight(1)
          .borderRadius(10)
          .backgroundColor($r('app.color.primary_soft'))
          .border({ width: 0.75, color: $r('app.color.card_rim') })
          .onClick(() => {
            this.triggerRouterCommand(this.hasActiveLayout(state) ? 'runDrc' : 'openPicker');
          })
        }
        .height('100%')
        .justifyContent(FlexAlign.SpaceBetween)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .padding(12)
  }

  build() {
    Stack() {
      // 光感氛围柔光层（遵循 base/dark 双态低饱和透明光晕）
      Row()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['12%', '10%'],
          radius: '78%',
          colors: [
            [$r('app.color.card_glow_primary'), 0.0],
            ['#00000000', 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      Row()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['90%', '92%'],
          radius: '65%',
          colors: [
            [$r('app.color.card_glow_accent'), 0.0],
            ['#00000000', 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      if (this.formDimension === 3) {
        this.buildWide2x4(this.snapshotState())
      } else {
        this.buildCompact2x2(this.snapshotState())
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(16)
    .border({ width: 0.85, color: $r('app.color.card_rim') })
    .clip(true)
  }
}
