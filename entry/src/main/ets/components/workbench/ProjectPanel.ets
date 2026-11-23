import { hongTuThemeState } from '../../store/ThemeStore';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { PanelHeading } from './PanelHeading';
import { WorkbenchIcon } from './WorkbenchIcon';
import { WorkspaceHistory } from '../../services/WorkspaceService';
import type { EngineeringDependency } from '../../services/EngineeringProjectService';
import type { FileRecoveryEntry } from '../../services/FileRecoveryService';

export interface ProjectRecoveryEntry extends FileRecoveryEntry {}

@Component
export struct ProjectPanel {
  @Prop panelWidth: number = 640;
  @Prop history: WorkspaceHistory[] = [];
  @Prop recoveryStatus: string = '';
  @Prop actionStatus: string = '';
  @Prop engineeringDependencies: EngineeringDependency[] = [];
  @Prop toolBundleAvailable: boolean = false;
  @Prop recoveryEntries: ProjectRecoveryEntry[] = [];
  @Prop recentEdits: string[] = [];
  closeAction: () => void = () => {};
  createAction: (library: string, topCell: string, dbuNm: number) => void = () => {};
  saveProjectAction: () => void = () => {};
  saveProjectAsAction: () => void = () => {};
  openProjectAction: () => void = () => {};
  checkpointAction: () => void = () => {};
  restoreAction: (item: WorkspaceHistory) => void = () => {};
  restoreToolContentsAction: () => void = () => {};
  recoverAction: (item: ProjectRecoveryEntry) => void = () => {};
  @State library: string = 'UNTITLED_LIB';
  @State topCell: string = 'TOP';
  @State dbu: string = '1';
  @State error: string = '';
  private dependencyStatus(status: string): string {
    switch (status) {
      case 'embedded': return '已嵌入';
      case 'available': return '可用';
      case 'missing': return '缺失';
      case 'required': return '需提供';
      default: return '未确认';
    }
  }
  private filteredActionStatus(): string {
    const raw: string = (this.actionStatus || '').trim();
    if (raw.length === 0) return '';
    if (raw.startsWith('视图已适配') || raw.startsWith('当前工具') || raw.startsWith('已切换当前绘图层') || raw === '就绪') {
      return '';
    }
    return raw;
  }

  private createDocument(): void {
    const dbu: number = Number(this.dbu);
    if (!/^[A-Za-z_][A-Za-z0-9_$?]{0,31}$/.test(this.library) || !/^[A-Za-z_][A-Za-z0-9_$?]{0,31}$/.test(this.topCell) ||
      !Number.isFinite(dbu) || dbu <= 0 || dbu > 1000000) {
      this.error = '名称须为 1–32 位，以字母或 _ 开头，后续可用字母、数字、_/$/?；DBU 须为正有限数';
      return;
    }
    this.error = '';
    this.createAction(this.library, this.topCell, dbu);
  }
  build() {
    Column({ space: 12 }) {
      PanelHeading({ title: '工程与恢复', closeAction: () => this.closeAction() })
      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 12 }) {
            Text('新建独立版图').utilitySectionTitle()
            Flex({ direction: this.panelWidth < 480 ? FlexDirection.Column : FlexDirection.Row }) {
              Column({ space: 6 }) {
                Text('库名').utilityLabel()
                TextInput({ text: this.library, placeholder: '库名' }).utilityInput().onChange((v: string) => this.library = v)
                  .onKeyEvent((event: KeyEvent) => event.stopPropagation())
              }.width(this.panelWidth < 480 ? '100%' : (this.panelWidth - UI.panelPadding * 4 - 12) / 2).margin({ right: this.panelWidth < 480 ? 0 : 12, bottom: this.panelWidth < 480 ? 12 : 0 })
              Column({ space: 6 }) {
                Text('顶层 Cell').utilityLabel()
                TextInput({ text: this.topCell, placeholder: '顶层 Cell' }).utilityInput().onChange((v: string) => this.topCell = v)
                  .onKeyEvent((event: KeyEvent) => event.stopPropagation())
              }.width(this.panelWidth < 480 ? '100%' : (this.panelWidth - UI.panelPadding * 4 - 12) / 2)
            }.width('100%')
            Column({ space: 6 }) {
              Text('DBU (nm)').utilityLabel()
              TextInput({ text: this.dbu }).utilityInput().onChange((v: string) => this.dbu = v)
                .onKeyEvent((event: KeyEvent) => event.stopPropagation())
            }.width(this.panelWidth < 480 ? '100%' : (this.panelWidth - UI.panelPadding * 4 - 12) / 2).alignSelf(ItemAlign.Start)
            if (this.error.length > 0) { Text(this.error).fontSize(12).fontColor(COLORS.danger).width('100%') }
            Row({ space: 8 }) {
              Button('新建版图', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius).onClick(() => this.createDocument())
              Button('打开工程', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).onClick(() => this.openProjectAction())
            }.width('100%')
            Row({ space: 8 }) {
              Button('保存工程', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).onClick(() => this.saveProjectAction())
              Button('工程另存…', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).onClick(() => this.saveProjectAsAction())
              Button('创建版本', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).onClick(() => this.checkpointAction())
            }.width('100%')
            if (this.recoveryStatus.length > 0) { Text(this.recoveryStatus).fontSize(12).fontColor(COLORS.primary).width('100%') }
            if (this.filteredActionStatus().length > 0) { Text(this.filteredActionStatus()).fontSize(12).fontColor(COLORS.ink).width('100%') }
          }.utilitySection()
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              Text(`工程依赖 (${this.engineeringDependencies.length})`).fontSize(14).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
              Button('恢复工具与审阅', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).fontSize(12).padding({ left: 8, right: 8 })
                .backgroundColor(Color.Transparent).fontColor(COLORS.primary).enabled(this.toolBundleAvailable).onClick(() => this.restoreToolContentsAction())
            }.width('100%')
            if (this.panelWidth >= 480 && this.engineeringDependencies.length > 0) {
              Row({ space: 12 }) {
                Text('名称').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
                Text('版本').fontSize(11).fontColor(COLORS.muted).width(110)
                Text('状态').fontSize(11).fontColor(COLORS.muted).width(72)
              }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 }).backgroundColor(COLORS.surfaceMuted).borderRadius(6)
            }
            ForEach(this.engineeringDependencies, (item: EngineeringDependency) => {
              Column({ space: 6 }) {
                Row({ space: 10 }) {
                  WorkbenchIcon({ name: item.kind.toLowerCase().includes('python') ? 'macro' : 'data', iconSize: 16, color: COLORS.muted })
                  Text(item.name).fontSize(13).fontColor(COLORS.ink).layoutWeight(1).maxLines(2)
                  if (this.panelWidth >= 480) {
                    Text(item.version || '版本未实测').fontSize(12).fontColor(COLORS.muted).width(110)
                  }
                  Text(this.dependencyStatus(item.status)).fontSize(12).fontColor(item.status === 'missing' ? COLORS.danger : COLORS.muted).width(72)
                }.width('100%')
                if (this.panelWidth < 480) { Text(item.version || '版本未实测').utilityHint() }
                Text(item.message).utilityHint()
              }.width('100%').padding({ top: 8, bottom: 10, left: 10, right: 10 }).border({ width: { bottom: 1 }, color: COLORS.border })
            }, (item: EngineeringDependency) => `${item.kind}:${item.name}`)
            if (!this.toolBundleAvailable) { Text('当前工程没有可恢复的脚本与规则包。').utilityHint() }
          }.utilitySection()
          if (this.recoveryEntries.length > 0) {
            Column({ space: 10 }) {
              Text(`安全保存副本 (${this.recoveryEntries.length})`).utilitySectionTitle()
              if (this.panelWidth >= 480) {
                Row({ space: 10 }) {
                  Text('文件名').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
                  Text('大小').fontSize(11).fontColor(COLORS.muted).width(64)
                  Text('创建时间').fontSize(11).fontColor(COLORS.muted).width(126)
                  Text('操作').fontSize(11).fontColor(COLORS.muted).width(96)
                }.width('100%').padding(8).backgroundColor(COLORS.surfaceMuted).borderRadius(6)
              }
              ForEach(this.recoveryEntries, (item: ProjectRecoveryEntry) => {
                Column({ space: 6 }) {
                  Row({ space: 8 }) {
                    WorkbenchIcon({ name: 'data', iconSize: 16, color: COLORS.muted })
                    Text(item.name).fontSize(12).fontColor(COLORS.ink).layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (this.panelWidth >= 480) {
                      Text(`${(item.bytes / 1024).toFixed(1)} KiB`).fontSize(11).fontColor(COLORS.muted).width(64)
                      Text(new Date(item.createdAt).toLocaleString()).fontSize(11).fontColor(COLORS.muted).width(126).maxLines(2)
                      Button('导出安全副本', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).fontSize(11).width(96).padding(0).backgroundColor(Color.Transparent).fontColor(COLORS.primary).onClick(() => this.recoverAction(item))
                    }
                  }.width('100%')
                  if (this.panelWidth < 480) {
                    Text(`${(item.bytes / 1024).toFixed(1)} KiB · ${new Date(item.createdAt).toLocaleString()}`).utilityHint()
                    Button('导出安全副本', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor(COLORS.primary).onClick(() => this.recoverAction(item))
                  }
                  Text(item.metadataMissing ? '原目标信息未保存，副本内容仍可导出' : item.targetUri).utilityHint()
                }.width('100%').padding({ top: 8, bottom: 10 }).border({ width: { bottom: 1 }, color: COLORS.border })
              }, (item: ProjectRecoveryEntry) => item.backupPath)
            }.utilitySection()
          }
          if (this.recentEdits.length > 0) {
            Column({ space: 8 }) {
              Text('最近操作摘要').utilitySectionTitle()
              ForEach(this.recentEdits.slice(0, 8), (item: string) => {
                Row({ space: 8 }) {
                  WorkbenchIcon({ name: 'edit', iconSize: 14, color: COLORS.muted })
                  Text(item).fontSize(12).fontColor(COLORS.muted).layoutWeight(1)
                }.width('100%')
              }, (item: string, index: number) => `${index}:${item}`)
            }.utilitySection()
          }
          Column({ space: 10 }) {
            Text(`当前版图版本 (${this.history.length})`).utilitySectionTitle()
            if (this.panelWidth >= 480 && this.history.length > 0) {
              Row({ space: 10 }) {
                Text('版本内容').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
                Text('时间').fontSize(11).fontColor(COLORS.muted).width(126)
                Text('操作').fontSize(11).fontColor(COLORS.muted).width(96)
              }.width('100%').padding(8).backgroundColor(COLORS.surfaceMuted).borderRadius(6)
            }
            ForEach(this.history, (item: WorkspaceHistory) => {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  WorkbenchIcon({ name: 'undo', iconSize: 16, color: COLORS.muted })
                  Text(item.title).fontSize(13).fontColor(COLORS.ink).layoutWeight(1).maxLines(2)
                  if (this.panelWidth >= 480) {
                    Text(new Date(item.createdAt).toLocaleString()).fontSize(11).fontColor(COLORS.muted).width(126).maxLines(2)
                  }
                  Button('恢复为副本', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).width(96).height(UI.compactControlHeight).fontSize(12).padding(0).backgroundColor(Color.Transparent).fontColor(COLORS.primary).onClick(() => this.restoreAction(item))
                }.width('100%')
                if (this.panelWidth < 480) { Text(new Date(item.createdAt).toLocaleString()).utilityHint() }
              }.width('100%').padding({ top: 8, bottom: 10 }).border({ width: { bottom: 1 }, color: COLORS.border })
            }, (item: WorkspaceHistory) => item.id)
            if (this.history.length === 0) { Text('尚未创建版图版本。').utilityHint().padding({ top: 8, bottom: 8 }) }
          }.utilitySection()
        }.width('100%').padding({ bottom: 4 })
      }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
    }
    .width(LayoutPolicy.matchParent)
    .height(LayoutPolicy.matchParent)
    .padding({ left: 18, right: 18, top: 8, bottom: 24 })
    .backgroundColor(Color.Transparent)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onKeyEvent((event: KeyEvent) => event.stopPropagation())
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
@Extend(Column)
function utilitySection() {
  .width('100%').padding(UI.panelPadding).backgroundColor(COLORS.surface)
  .border({ width: 1, color: COLORS.border }).borderRadius(UI.panelRadius).alignItems(HorizontalAlign.Start)
}
@Extend(Text)
function utilitySectionTitle() {
  .fontSize(14).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
}
@Extend(Text)
function utilityLabel() {
  .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
}
@Extend(Text)
function utilityHint() {
  .fontSize(11).fontColor(COLORS.muted).width('100%')
}
