import { hongTuThemeState } from '../../store/ThemeStore';
import { common } from '@kit.AbilityKit';
import { Macro, MacroStep, macroService } from '../../services/MacroService';
import { readAutomationText, saveAutomationText } from '../../services/AutomationFiles';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct MacroManagerDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  onChanged: () => void = () => {};
  @State items: Macro[] = [];
  @State selectedId: number = -1;
  @State nameText: string = '';
  @State descriptionText: string = '';
  @State stepsText: string = '[]';
  @State status: string = '';
  @State builtin: boolean = false;
  @State busy: boolean = false;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate(); this.refresh(); }
  private refresh(): void { this.items = macroService.getAllMacros().slice(); this.onChanged(); }
  private select(item: Macro): void {
    this.selectedId = item.id; this.nameText = item.name; this.descriptionText = item.description;
    this.stepsText = JSON.stringify(item.steps, null, 2); this.builtin = item.builtin;
    this.status = item.builtin ? '内置宏可另存副本后编辑' : '';
  }
  private save(copy: boolean): void {
    try {
      const steps = JSON.parse(this.stepsText) as MacroStep[];
      if (!this.nameText.trim() || this.nameText.length > 120 || !macroService.validSteps(steps)) {
        throw new Error('请填写名称和 1–1000 个有效步骤；每步需要 description、command、type');
      }
      if (copy || this.selectedId < 0) {
        const originDocumentId: string | undefined = this.selectedId >= 0
          ? macroService.getMacro(this.selectedId)?.originDocumentId : undefined;
        const item = macroService.createMacro(this.nameText.trim() + (copy ? ' 副本' : ''), this.descriptionText, steps, originDocumentId);
        this.select(item);
      } else if (!macroService.updateMacro(this.selectedId, { name: this.nameText.trim(), description: this.descriptionText, steps })) {
        throw new Error('内置宏不可覆盖，请另存副本');
      }
      this.refresh(); this.status = '宏已保存';
    } catch (error) { this.status = String(error); }
  }
  private remove(): void {
    const id = this.selectedId;
    AlertDialog.show({ title: '删除自定义宏', message: `删除「${this.nameText}」？`,
      cornerRadius: UI.dialogRadius, backgroundColor: COLORS.surface,
      primaryButton: { value: '取消', fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, action: () => {} },
      secondaryButton: { value: '删除', fontColor: COLORS.danger, backgroundColor: COLORS.dangerSoft, action: () => {
        try {
          if (macroService.deleteMacro(id)) {
            if (this.selectedId === id) this.selectedId = -1;
            this.refresh(); this.status = '已删除';
          } else this.status = '该宏已变化或不可删除，请重新选择';
        } catch (error) { this.status = `删除未保存，原宏保留：${String(error)}`; }
      } } });
  }
  private async transfer(importing: boolean): Promise<void> {
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (importing) {
        const text = await readAutomationText(context, '宏文件|.json');
        if (text !== null) { const count = macroService.importCollection(text); this.refresh(); this.status = `已导入 ${count} 个宏`; }
      } else {
        const text = this.selectedId >= 0 ? macroService.exportMacro(this.selectedId) : macroService.exportAllMacros();
        if (text && await saveAutomationText(context, 'hongtu-macros.json', text)) this.status = '已导出 JSON 文件';
      }
    } catch (error) { this.status = String(error); }
    finally { this.busy = false; }
  }
  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column({ space: 12 }) {
      Text('宏管理').fontSize(UI.titleSize).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.items, (item: Macro) => {
            Button({ type: ButtonType.Normal }) {
              Text(`${item.name} · ${item.steps.length} 步`).width('100%').textAlign(TextAlign.Start)
                .fontSize(UI.fontBody).fontColor(item.id === this.selectedId ? COLORS.primary : COLORS.ink)
            }.width('100%').height(48).padding({ left: 12, right: 12 }).borderRadius(UI.controlRadius)
              .backgroundColor(item.id === this.selectedId ? COLORS.primarySoft : COLORS.surface)
              .onClick(() => this.select(item))
          }, (item: Macro) => `${item.id}-${item.updatedAt}`)
        }.width('100%')
      }.height(110).width('100%').padding(4).align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clipContent(ContentClipMode.SAFE_AREA)
        .backgroundColor(COLORS.surface).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
      Column({ space: 8 }) {
        Text('宏名称').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
        TextInput({ text: this.nameText, placeholder: '宏名称' }).height(UI.fieldHeight).fontSize(UI.fontBody)
          .fontColor(COLORS.ink).placeholderColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .defaultFocus(true).onFocus(() => { resetModifierKeys(); })
          .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); }).onChange((value: string) => { this.nameText = value; })
      }.width('100%')
      Column({ space: 8 }) {
        Text('用途说明').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
        TextInput({ text: this.descriptionText, placeholder: '用途说明' }).height(UI.fieldHeight).fontSize(UI.fontBody)
          .fontColor(COLORS.ink).placeholderColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onFocus(() => { resetModifierKeys(); }).onKeyEvent((event: KeyEvent) => { event.stopPropagation(); }).onChange((value: string) => { this.descriptionText = value; })
      }.width('100%')
      Column({ space: 8 }) {
        Text('步骤 JSON').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
        TextArea({ text: this.stepsText }).height(200).fontSize(UI.fontBody).fontFamily('monospace')
          .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onFocus(() => { resetModifierKeys(); }).onKeyEvent((event: KeyEvent) => { event.stopPropagation(); }).onChange((value: string) => { this.stepsText = value; })
      }.width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('导入', { type: ButtonType.Normal }).enabled(!this.busy).onClick(() => this.transfer(true))
          .height(UI.controlHeight).constraintSize({ minWidth: 100 }).flexGrow(1).margin({ right: 8, bottom: 8 }).padding({ left: 12, right: 12 }).fontSize(UI.fontBody).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
        Button('导出', { type: ButtonType.Normal }).enabled(!this.busy).onClick(() => this.transfer(false))
          .height(UI.controlHeight).constraintSize({ minWidth: 100 }).flexGrow(1).margin({ right: 8, bottom: 8 }).padding({ left: 12, right: 12 }).fontSize(UI.fontBody).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
        Button('另存副本', { type: ButtonType.Normal }).enabled(!this.busy).onClick(() => this.save(true))
          .height(UI.controlHeight).constraintSize({ minWidth: 100 }).flexGrow(1).margin({ right: 8, bottom: 8 }).padding({ left: 12, right: 12 }).fontSize(UI.fontBody).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
        Button('删除', { type: ButtonType.Normal }).enabled(!this.busy && this.selectedId >= 0 && !this.builtin).onClick(() => this.remove())
          .height(UI.controlHeight).constraintSize({ minWidth: 100 }).flexGrow(1).margin({ right: 8, bottom: 8 }).padding({ left: 12, right: 12 }).fontSize(UI.fontBody).borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.dangerSoft).fontColor(COLORS.danger)
      }.width('100%')
      Row({ space: 12 }) {
        Text(this.status).fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1)
        Button('完成', { type: ButtonType.Normal }).attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy).onClick(() => this.controller.close())
          .height(UI.controlHeight).fontSize(UI.fontBody).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
        Button('保存', { type: ButtonType.Normal }).attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy && !this.builtin).onClick(() => this.save(false))
          .height(UI.controlHeight).fontSize(UI.fontBody).borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.primary).fontColor(Color.White)
      }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border }).margin({ top: 8 })
    }.padding(UI.dialogPadding).width('92%').constraintSize({ maxWidth: 620 }).backgroundColor(COLORS.surface).borderRadius(UI.dialogRadius)
      .transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
