import { hongTuThemeState } from '../../store/ThemeStore';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { PanelHeading } from './PanelHeading';
import { WorkbenchIcon } from './WorkbenchIcon';
import { ComponentLibraryEntry } from '../../services/ComponentLibraryService';

@Component
export struct ComponentLibraryPanel {
  @Prop panelWidth: number = 640;
  @Prop entries: ComponentLibraryEntry[] = [];
  @Prop selectedPCellName: string = '';
  @Prop actionStatus: string = '';
  closeAction: () => void = () => {};
  editPCellAction: () => void = () => {};
  addPresetAction: (title: string, category: string) => void = () => {};
  addCellAction: (title: string, category: string) => void = () => {};
  insertAction: (entry: ComponentLibraryEntry, x: number, y: number) => void = () => {};
  removeAction: (id: string) => void = () => {};
  importAction: () => void = () => {};
  exportAction: () => void = () => {};
  @State search: string = '';
  @State title: string = '';
  @State category: string = '个人器件';
  @State posX: string = '0';
  @State posY: string = '0';
  @State error: string = '';
  private filtered(): ComponentLibraryEntry[] {
    const query: string = this.search.trim().toLowerCase();
    return this.entries.filter((entry: ComponentLibraryEntry) => `${entry.title} ${entry.category} ${entry.pcellName}`.toLowerCase().includes(query));
  }
  private insert(entry: ComponentLibraryEntry): void {
    const x: number = Number(this.posX), y: number = Number(this.posY);
    if (!Number.isFinite(x) || !Number.isFinite(y) || !this.posX.trim() || !this.posY.trim()) { this.error = '放置坐标无效'; return; }
    this.error = ''; this.insertAction(entry, x, y);
  }
  build() {
    Column({ space: 16 }) {
      PanelHeading({ title: '个人器件库', closeAction: () => this.closeAction() })
      if (this.selectedPCellName.length > 0) {
        Row({ space: 10 }) {
          WorkbenchIcon({ name: 'instance', iconSize: 18, color: COLORS.muted })
          Column({ space: 3 }) {
            Text('选中参数化器件').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            Text(this.selectedPCellName).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.primary).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1)
          Button('修改参数', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).onClick(() => this.editPCellAction())
        }.width('100%').padding(12).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
      }
      Column({ space: 12 }) {
        Text('添加收藏').fontSize(14).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
        Flex({ direction: this.panelWidth < 480 ? FlexDirection.Column : FlexDirection.Row }) {
          Column({ space: 6 }) {
            Text('收藏名称').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            TextInput({ text: this.title, placeholder: '收藏名称' }).utilityInput()
              .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((v: string) => this.title = v)
          }.width(this.panelWidth < 480 ? '100%' : (this.panelWidth - UI.panelPadding * 2 - 12) / 2).margin({ right: this.panelWidth < 480 ? 0 : 12, bottom: this.panelWidth < 480 ? 12 : 0 })
          Column({ space: 6 }) {
            Text('分类').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            TextInput({ text: this.category, placeholder: '分类' }).utilityInput()
              .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((v: string) => this.category = v)
          }.width(this.panelWidth < 480 ? '100%' : (this.panelWidth - UI.panelPadding * 2 - 12) / 2)
        }.width('100%')
        Row({ space: 8 }) {
          Button('收藏当前 Cell', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
            .layoutWeight(this.panelWidth < 480 ? 1 : 0).onClick(() => this.addCellAction(this.title, this.category))
          Button('收藏 PCell 参数', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(this.panelWidth < 480 ? 1 : 0)
            .enabled(this.selectedPCellName.length > 0).onClick(() => this.addPresetAction(this.title, this.category))
        }.width('100%')
      }.width('100%').padding({ bottom: 16 }).border({ width: { bottom: 1 }, color: COLORS.border })
      Row({ space: 8 }) {
        Text(`器件列表 (${this.filtered().length})`).fontSize(14).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
        Button('导入', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).onClick(() => this.importAction())
        Button('导出', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).onClick(() => this.exportAction())
      }.width('100%')
      Flex({ direction: this.panelWidth < 480 ? FlexDirection.Column : FlexDirection.Row }) {
        Search({ value: this.search, placeholder: '搜索名称、分类或器件类型' })
          .height(UI.fieldHeight).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((v: string) => this.search = v)
          .width(this.panelWidth < 480 ? '100%' : (this.panelWidth - UI.panelPadding * 2 - 12) / 2).margin({ right: this.panelWidth < 480 ? 0 : 12, bottom: this.panelWidth < 480 ? 12 : 0 })
        Row({ space: 6 }) {
          Text('放置 nm').fontSize(UI.fontCaption).fontColor(COLORS.muted)
          Text('X').fontSize(UI.fontCaption).fontColor(COLORS.muted)
          TextInput({ text: this.posX, placeholder: 'X' }).utilityInput().layoutWeight(1)
            .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((v: string) => this.posX = v)
          Text('Y').fontSize(UI.fontCaption).fontColor(COLORS.muted)
          TextInput({ text: this.posY, placeholder: 'Y' }).utilityInput().layoutWeight(1)
            .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((v: string) => this.posY = v)
        }.width(this.panelWidth < 480 ? '100%' : (this.panelWidth - UI.panelPadding * 2 - 12) / 2)
      }.width('100%')
      if (this.actionStatus.length > 0) { Text(this.actionStatus).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%') }
      if (this.error.length > 0) { Text(this.error).fontSize(12).fontColor(COLORS.danger).width('100%') }
      Column() {
        if (this.panelWidth >= 480) {
          Row({ space: 10 }) {
            Text('名称').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('36%')
            Text('分类 · 器件类型').fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1)
            Text('操作').fontSize(UI.fontCaption).fontColor(COLORS.muted).width(122)
          }.width('100%').height(36).padding({ left: 12, right: 12 }).backgroundColor(COLORS.surfaceMuted)
        }
        Scroll() {
          Column() {
            ForEach(this.filtered(), (entry: ComponentLibraryEntry) => {
              Row({ space: 10 }) {
                if (this.panelWidth >= 480) {
                  Row({ space: 8 }) {
                    WorkbenchIcon({ name: entry.pcellName ? 'instance' : 'layout', iconSize: 16, color: COLORS.muted })
                    Text(entry.title).fontSize(UI.fontBody).fontColor(COLORS.ink).layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.width('36%')
                  Text(`${entry.category} · ${entry.pcellName || '层级 Cell'}`).fontSize(UI.fontCaption).fontColor(COLORS.muted)
                    .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                } else {
                  Column({ space: 5 }) {
                    Text(entry.title).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%').maxLines(2)
                    Text(`${entry.category} · ${entry.pcellName || '层级 Cell'}`).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%').maxLines(2)
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }
                Row({ space: 6 }) {
                  Button('放置', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).width(64).padding(0)
                    .backgroundColor(COLORS.surface).fontColor(COLORS.primary).border({ width: 1, color: COLORS.primarySoft }).borderRadius(UI.controlRadius).onClick(() => this.insert(entry))
                  Button('删除', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).width(52).padding(0)
                    .backgroundColor(COLORS.dangerSoft).fontColor(COLORS.danger).border({ width: 1, color: COLORS.dangerSoft }).borderRadius(UI.controlRadius).onClick(() => this.removeAction(entry.id))
                }.width(122)
              }.width('100%').padding(12).constraintSize({ minHeight: 56 }).border({ width: { bottom: 1 }, color: COLORS.border })
            }, (entry: ComponentLibraryEntry) => entry.id)
            if (this.entries.length === 0) { Text('暂无收藏器件').fontSize(13).fontColor(COLORS.muted).width('100%').padding(24) }
            else if (this.filtered().length === 0) { Text('无匹配器件').fontSize(13).fontColor(COLORS.muted).width('100%').padding(24) }
          }.width('100%')
        }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      }.layoutWeight(1).width('100%').border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).clip(true)
    }.width(this.panelWidth).height('85%').constraintSize({ maxWidth: '94%', maxHeight: 740 }).padding(UI.panelPadding)
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
