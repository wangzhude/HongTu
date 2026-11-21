import { hongTuThemeState, Radius } from '../../store/ThemeStore';
import { COLORS } from '../../common/constants';
import { ThemeManager } from '../../common/Theme';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { WorkbenchCommand, searchWorkbenchCommands } from '../../services/CommandSearchService';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct CommandSearchDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  commandsProvider: () => WorkbenchCommand[] = () => [];
  executeAction: (id: string) => boolean = (_id: string) => false;
  @State query: string = '';
  @State commands: WorkbenchCommand[] = [];
  @State detail: string = '';

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate(); this.query = ''; this.detail = ''; this.commands = this.commandsProvider(); }
  private run(command: WorkbenchCommand): void {
    const latest: WorkbenchCommand | undefined = this.commandsProvider().find((item: WorkbenchCommand) => item.id === command.id);
    if (latest === undefined || !latest.enabled) {
      this.detail = latest === undefined ? '命令已不可用，请重新打开搜索' : `${latest.reason}。${latest.nextStep}`;
      this.commands = this.commandsProvider();
      return;
    }
    if (this.executeAction(command.id)) this.controller.close();
    else { this.commands = this.commandsProvider(); this.detail = '命令未执行，请检查当前文档和操作范围'; }
  }
  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    WithTheme({
      theme: ThemeManager.nativeTheme(),
      colorMode: ThemeManager.colorMode()
    }) {
    Column({ space: 16 }) {
      Row() {
        Text('搜索命令').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink)
        Blank()
        Text('Ctrl+K').fontSize(UI.fontCaption).fontColor(COLORS.muted)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([COLORS.ink])
        }.width(34).height(34).borderRadius(Radius.pill)
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border })
          .margin({ left: 10 })
          .accessibilityText('关闭命令搜索').onClick(() => this.controller.close())
      }.width('100%').alignItems(VerticalAlign.Center)
      Search({ value: this.query, placeholder: '输入任务：画圆、只改此处、布尔、批量属性、保存…' })
        .defaultFocus(true)
        .onFocus(() => { resetModifierKeys(); })
        .width('100%')
        .height(UI.fieldHeight)
        .textFont({ size: UI.fontBody })
        .placeholderFont({ size: UI.fontBody })
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .searchIcon({ size: 16, color: COLORS.muted })
        .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 14, color: COLORS.muted } })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .onChange((value: string) => { this.query = value; })
        .onKeyEvent((event: KeyEvent) => event.stopPropagation())
      if (this.detail.length > 0) Text(this.detail).fontSize(UI.fontCaption).fontColor(COLORS.danger).width('100%')
      List({ space: 0 }) {
        ForEach(searchWorkbenchCommands(this.commands, this.query), (command: WorkbenchCommand) => {
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Text(command.title).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(command.enabled ? COLORS.ink : COLORS.muted)
                  Text(command.enabled ? command.nextStep : `${command.reason} · ${command.nextStep}`)
                    .fontSize(UI.fontCaption).fontColor(COLORS.muted).maxLines(2)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                if (command.shortcut.trim().length > 0) {
                  Text(command.shortcut).fontSize(UI.fontCaption).fontColor(COLORS.muted)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 }).backgroundColor(COLORS.surfaceMuted)
                    .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                }
              }.width('100%')
            }.width('100%').padding({ left: 12, right: 12, top: 12, bottom: 12 }).backgroundColor(COLORS.surface)
              .border({ width: { bottom: 1 }, color: COLORS.border })
              .borderRadius(UI.controlRadius)
              .onClick(() => this.run(command))
          }
        }, (command: WorkbenchCommand) => command.id)
      }.width('100%').height(searchWorkbenchCommands(this.commands, this.query).length === 0 ? 72 : 360)
        .backgroundColor(COLORS.surface).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .align(Alignment.TopStart)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(true)
      if (searchWorkbenchCommands(this.commands, this.query).length === 0) {
        Text('无匹配命令').fontSize(UI.fontCaption).fontColor(COLORS.muted)
      }
    }.width(600).constraintSize({ maxWidth: '94%' }).padding(UI.dialogPadding)
      .backgroundColor(COLORS.surface)
      .border({ width: 1, color: COLORS.border })
      .borderRadius(UI.dialogRadius)
      .clip(true)
      .transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => event.stopPropagation())
    }
  }
}
