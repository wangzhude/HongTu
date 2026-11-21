import { hongTuThemeState } from '../../store/ThemeStore';
import { common } from '@kit.AbilityKit';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { PanelHeading } from './PanelHeading';
import { parseTechnologyPackage, technologyTemplate, sky130SubsetTechnology, klayoutDemoTechnology } from '../../common/technologyPackage';
import type { TechnologyPackage, TechnologyParseResult } from '../../common/technologyPackage';
import { technologyService } from '../../services/TechnologyService';
import { engineeringFileService } from '../../services/EngineeringFileService';

interface TechnologyTemplateBtnParams {
  label: string;
  technology: TechnologyPackage;
}

@Component
export struct TechnologyPanel {
  @Prop panelWidth: number = 620;
  @Prop panelHeight: number = 720;
  applyAction: (technology: TechnologyPackage) => void = () => {};
  clearAction: () => void = () => {};
  closeAction: () => void = () => {};
  layerStackAction: () => void = () => {};
  revisionProvider: () => string = () => '';
  @State draft: string = '';
  @State status: string = '';
  @State activeName: string = '';
  @State hasActiveTechnology: boolean = false;
  @State busy: boolean = false;
  @State summary: string = '';
  private active: boolean = true;
  private openedRevision: string = '';
  aboutToAppear(): void {
    this.active = true;
    this.openedRevision = this.revisionProvider();
    const active: TechnologyPackage | undefined = technologyService.getActive();
    this.hasActiveTechnology = active !== undefined;
    this.activeName = active === undefined ? '当前文档未绑定工艺' : `${active.name} ${active.version}`;
    this.draft = JSON.stringify(active ?? technologyTemplate(), null, 2);
    this.validateDraft();
  }
  aboutToDisappear(): void { this.active = false; }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private validateDraft(): TechnologyParseResult {
    const parsed: TechnologyParseResult = parseTechnologyPackage(this.draft);
    const tech: TechnologyPackage | undefined = parsed.technology;
    this.summary = parsed.ok && tech !== undefined
      ? `${tech.name} · ${tech.layers.length} 对图层 · ${tech.viaLayers.length} 通孔映射 · ${tech.drcRules.length} DRC规则 · ${tech.devices.length} 器件绑定`
      : `工艺包无效：${parsed.error}`;
    return parsed;
  }
  private setTemplate(technology: TechnologyPackage): void {
    if (this.busy) return;
    this.draft = JSON.stringify(technology, null, 2); this.validateDraft(); this.status = '模板已载入，点击“应用到当前文档”生效';
  }
  private applyDraft(): void {
    if (this.busy || !this.active) return;
    if (this.openedRevision !== this.revisionProvider()) { this.status = '文档已变化，请重新打开工艺配置后应用'; return; }
    const parsed: TechnologyParseResult = this.validateDraft();
    if (!parsed.ok || parsed.technology === undefined) { this.status = parsed.error; return; }
    try {
      this.applyAction(parsed.technology);
      this.openedRevision = this.revisionProvider();
      this.activeName = `${parsed.technology.name} ${parsed.technology.version}`;
      this.hasActiveTechnology = technologyService.getActive() !== undefined;
      this.status = '已绑定图层、通孔映射和规则；几何层号保持原值';
    } catch (error) { this.status = error instanceof Error ? error.message : String(error); }
  }
  private async importPackage(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    try {
      const draft: string = await engineeringFileService.pickJson(this.context());
      if (!this.active) return;
      if (this.openedRevision !== this.revisionProvider()) throw new Error('文档已变化，请重新打开工艺配置后导入');
      const parsed: TechnologyParseResult = parseTechnologyPackage(draft);
      if (!parsed.ok) throw new Error(parsed.error);
      this.draft = draft; this.validateDraft(); this.status = '已读取工艺包，检查后应用';
    }
    catch (error) { if (this.active) this.status = error instanceof Error ? error.message : String(error); }
    finally { this.busy = false; }
  }
  private async exportPackage(): Promise<void> {
    if (this.busy) return;
    const parsed: TechnologyParseResult = this.validateDraft();
    if (!parsed.ok || parsed.technology === undefined) return;
    this.busy = true;
    try {
      await engineeringFileService.saveText(this.context(), `${parsed.technology.id}.technology.json`, JSON.stringify(parsed.technology, null, 2));
      if (this.active) this.status = '工艺包已导出';
    } catch (error) { if (this.active) this.status = error instanceof Error ? error.message : String(error); }
    finally { this.busy = false; }
  }
  private matchesTemplate(technology: TechnologyPackage): boolean {
    return this.draft === JSON.stringify(technology, null, 2);
  }
  @Builder
  private templateButton(params: TechnologyTemplateBtnParams) {
    Button(params.label, { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontSize(UI.fontBody).padding({ left: 12, right: 12 })
      .backgroundColor(this.matchesTemplate(params.technology) ? COLORS.primarySoft : COLORS.surfaceMuted)
      .fontColor(this.matchesTemplate(params.technology) ? COLORS.primary : COLORS.ink)
      .border({ width: 1, color: this.matchesTemplate(params.technology) ? COLORS.primarySoft : COLORS.border }).borderRadius(UI.controlRadius)
      .margin({ right: 8, bottom: 8 }).enabled(!this.busy).onClick(() => this.setTemplate(params.technology))
  }
  build() {
    Column({ space: 16 }) {
      PanelHeading({ title: '工艺与器件库', closeAction: () => this.closeAction() })
      Flex({ direction: this.panelWidth < 520 ? FlexDirection.Column : FlexDirection.Row }) {
        Row({ space: 8 }) {
          Text('当前工艺').fontSize(UI.fontCaption).fontColor(COLORS.muted)
          Text(this.activeName).fontSize(UI.fontBody).fontColor(COLORS.primary).maxLines(2)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 }).backgroundColor(COLORS.primarySoft).borderRadius(6)
        }.width(this.panelWidth < 520 ? '100%' : '48%').margin({ bottom: this.panelWidth < 520 ? 12 : 0 })
        Row({ space: 6 }) {
          Button('导入工艺包', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).fontSize(12).padding({ left: 8, right: 8 }).enabled(!this.busy).onClick(() => { this.importPackage(); })
          Button('导出工艺包', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).fontSize(12).padding({ left: 8, right: 8 }).enabled(!this.busy).onClick(() => { this.exportPackage(); })
          Button('解除绑定', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).fontSize(12).padding({ left: 8, right: 8 })
            .backgroundColor(COLORS.dangerSoft).fontColor(COLORS.danger).border({ width: 1, color: COLORS.dangerSoft }).borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => {
            if (this.openedRevision !== this.revisionProvider()) { this.status = '文档已变化，请重新打开工艺配置'; return; }
            try {
              this.clearAction(); this.openedRevision = this.revisionProvider();
              this.activeName = '当前文档未绑定工艺'; this.hasActiveTechnology = false; this.status = '已解除工艺绑定';
            } catch (error) { this.status = error instanceof Error ? error.message : String(error); }
          })
        }.width(this.panelWidth < 520 ? '100%' : '52%')
      }.width('100%')
      Column({ space: 8 }) {
        Text('模板').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          this.templateButton({ label: '空白模板', technology: technologyTemplate() })
          this.templateButton({ label: 'SKY130 M1 子集', technology: sky130SubsetTechnology() })
          this.templateButton({ label: 'MOS4 演示', technology: klayoutDemoTechnology() })
        }.width('100%')
      }.width('100%').padding({ bottom: 16 }).border({ width: { bottom: 1 }, color: COLORS.border })
      Text(this.summary).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      Button('物理层栈、截面与三维网格', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).width('100%')
        .enabled(!this.busy && this.hasActiveTechnology).onClick(() => this.layerStackAction())
      Column({ space: 12 }) {
        Text('工艺配置 JSON').fontSize(14).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
        TextArea({ text: this.draft, placeholder: 'hongtu-technology/v1 JSON' })
          .layoutWeight(1).width('100%').fontSize(12).fontFamily('monospace').fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).padding(12).enabled(!this.busy)
          .onChange((value: string) => { this.draft = value; })
      }.layoutWeight(1).width('100%')
      Flex({ direction: this.panelWidth < 480 ? FlexDirection.Column : FlexDirection.Row }) {
        if (this.status.length > 0) {
          Text(this.status).fontSize(12).fontColor(COLORS.accent)
            .width(this.panelWidth < 480 ? '100%' : '50%').margin({ bottom: this.panelWidth < 480 ? 10 : 0 }).maxLines(2)
        } else if (this.panelWidth >= 480) {
          Blank().width('50%')
        }
        Row({ space: 8 }) {
          Button('检查配置', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontSize(12).layoutWeight(1).enabled(!this.busy).onClick(() => { this.validateDraft(); })
          Button('应用到当前文档', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontSize(12).layoutWeight(1.6)
            .backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => this.applyDraft())
        }.width(this.panelWidth < 480 ? '100%' : '50%')
      }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
    }.width(this.panelWidth).height(this.panelHeight).padding(UI.panelPadding)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay')))
  }
}

@Extend(Button)
function utilityButton() {
  .height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).hoverEffect(HoverEffect.Highlight)
}

@Extend(TextInput)
function utilityInput() {
  .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
}
