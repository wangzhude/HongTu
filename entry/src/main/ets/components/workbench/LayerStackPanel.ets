import { SettingsToggleRow } from '../SettingsKit';
import { hongTuThemeState } from '../../store/ThemeStore';
import { common } from '@kit.AbilityKit';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import type { TechnologyPackage } from '../../common/technologyPackage';
import { PHYSICAL_LAYER_STACK_SCHEMA, parsePhysicalLayerStack } from '../../models/PhysicalLayerStack';
import type { PhysicalLayerStack, PhysicalLayerLevel, PhysicalMaterial, PhysicalStackParseResult } from '../../models/PhysicalLayerStack';
import type { LayerStackBounds, LayerStackSectionLine, LayerStackPreview, LayerStackResult } from '../../services/LayerStackService';
import { layerStackExportService } from '../../services/LayerStackExportService';
import { engineeringFileService } from '../../services/EngineeringFileService';
import { PanelHeading } from './PanelHeading';
import { LayerStackGeometryPanel } from './LayerStackGeometryPanel';
import { GeometryNumberField } from '../dialogs/GeometryNumberField';
import { cloneStructured } from '../../common/CloneUtils';

export interface LayerStackBuildOptions {
  precisionNm: number; boundsNm: LayerStackBounds; sectionLine: LayerStackSectionLine;
  coordinatePolicy: 'strict' | 'quantize';
}
interface StackFormField { key: string; label: string; value: string; }

@Component
export struct LayerStackPanel {
  @Prop panelWidth: number = 1020;
  @Prop panelHeight: number = 780;
  @Prop @Watch('contextChanged') inputContext: string = '';
  technologyProvider: () => TechnologyPackage | undefined = () => undefined;
  contextProvider: () => string = () => '';
  buildAction: (stack: PhysicalLayerStack, options: LayerStackBuildOptions) => LayerStackResult = () => ({ ok: false, message: '层栈未就绪' });
  saveAction: (stack: PhysicalLayerStack) => void = () => {};
  closeAction: () => void = () => {};
  @State stack: PhysicalLayerStack = { schema: PHYSICAL_LAYER_STACK_SCHEMA, id: 'user-stack', name: '用户物理层栈', unit: 'nm', materials: [], levels: [], processes: [] };
  @State draft: string = '';
  @State status: string = '';
  @State levelIndex: number = 0;
  @State materialIndex: number = 0;
  @State levelMaterialIndex: number = 0;
  @State sourceExpression: string = '';
  @State levelName: string = '';
  @State materialName: string = '';
  @State materialColor: string = '#327CE8';
  @State relativePermittivity: string = '';
  @State conductivity: string = '';
  @State backgroundMaterial: boolean = false;
  @State fields: StackFormField[] = [];
  @State geometryFields: StackFormField[] = [
    { key: 'precision', label: 'XY 模型精度 (nm)', value: '1' },
    { key: 'minX', label: 'ROI X 最小 (nm)', value: '-10000' }, { key: 'maxX', label: 'ROI X 最大 (nm)', value: '10000' },
    { key: 'minY', label: 'ROI Y 最小 (nm)', value: '-10000' }, { key: 'maxY', label: 'ROI Y 最大 (nm)', value: '10000' },
    { key: 'sx', label: '截线起点 X (nm)', value: '-10000' }, { key: 'sy', label: '截线起点 Y (nm)', value: '0' },
    { key: 'ex', label: '截线终点 X (nm)', value: '10000' }, { key: 'ey', label: '截线终点 Y (nm)', value: '0' }
  ];
  @State quantize: boolean = false;
  @State mode: number = 0;
  @State preview: LayerStackPreview | undefined = undefined;
  @State busy: boolean = false;
  @State advanced: boolean = false;
  @State opaque: boolean = false;
  private openedContext: string = '';
  private previewContext: string = '';
  private previewInput: string = '';
  private previewGeometrySeal: string = '';
  private active: boolean = true;
  private levelPending: boolean = false;
  private materialPending: boolean = false;
  private jsonPending: boolean = false;

  aboutToAppear(): void {
    this.active = true; this.openedContext = this.contextProvider();
    const saved: PhysicalLayerStack | undefined = this.technologyProvider()?.layerStack;
    if (saved !== undefined) { this.stack = cloneStructured(saved) as PhysicalLayerStack; this.opaque = saved.schema !== PHYSICAL_LAYER_STACK_SCHEMA; }
    this.syncDraft(); this.pickLevel(0); this.pickMaterial(0);
    this.status = this.opaque ? '未知层栈格式已保留，仅支持 JSON 查看与保存' : '';
  }
  aboutToDisappear(): void { this.active = false; this.preview = undefined; }
  private contextChanged(): void {
    if (!this.active || this.matches()) return;
    this.invalidate(); this.status = '文档或工艺已变化，旧预览已清除；请重新打开层栈';
  }
  private matches(): boolean { return this.active && this.openedContext === this.contextProvider(); }
  private invalidate(): void { this.preview = undefined; this.previewInput = ''; this.previewContext = ''; this.previewGeometrySeal = ''; }
  private syncDraft(): void { this.draft = JSON.stringify(this.stack, null, 2); this.jsonPending = false; }
  private number(text: string, label: string): number {
    if (!/^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/.test(text.trim()) || !Number.isFinite(Number(text))) throw new Error(`请填写有限数值：${label}`);
    return Number(text);
  }
  private value(fields: StackFormField[], key: string): number {
    const field: StackFormField | undefined = fields.find((row: StackFormField): boolean => row.key === key);
    return this.number(field?.value ?? '', field?.label ?? key);
  }
  private setField(key: string, value: string, geometry: boolean): void {
    this.invalidate();
    if (geometry) this.geometryFields = this.geometryFields.map((row: StackFormField): StackFormField => ({ key: row.key, label: row.label, value: row.key === key ? value : row.value }));
    else { this.fields = this.fields.map((row: StackFormField): StackFormField => ({ key: row.key, label: row.label, value: row.key === key ? value : row.value })); this.levelPending = true; }
    this.status = geometry ? '几何参数已修改，请重新生成几何' : '层参数已修改，请重新生成几何';
  }
  private flush(): void {
    if (this.jsonPending) {
      const parsed: PhysicalStackParseResult = parsePhysicalLayerStack(this.draft, this.technologyProvider()?.layers);
      if (!parsed.ok || parsed.stack === undefined) throw new Error(parsed.message);
      this.stack = parsed.stack; this.opaque = !parsed.executable; this.levelPending = false; this.materialPending = false;
      this.syncDraft(); this.pickLevel(0); this.pickMaterial(0); return;
    }
    const next: PhysicalLayerStack = cloneStructured(this.stack) as PhysicalLayerStack;
    if (this.materialPending) {
      const material: PhysicalMaterial | undefined = next.materials[this.materialIndex]; if (material === undefined) throw new Error('材料已变化，请重新选择');
      material.name = this.materialName; material.color = this.materialColor;
      material.relativePermittivity = this.relativePermittivity.trim().length ? this.number(this.relativePermittivity, '相对介电常数') : undefined;
      material.conductivitySm = this.conductivity.trim().length ? this.number(this.conductivity, '电导率 S/m') : undefined;
    }
    if (this.levelPending) {
      const level: PhysicalLayerLevel | undefined = next.levels[this.levelIndex]; if (level === undefined) throw new Error('层定义已变化，请重新选择');
      level.name = this.levelName; level.sourceExpression = this.sourceExpression; level.materialId = next.materials[this.levelMaterialIndex]?.id ?? '';
      level.zmin = this.value(this.fields, 'zmin'); level.thickness = this.value(this.fields, 'thickness');
      level.sidewallAngleDeg = this.value(this.fields, 'sidewall'); level.widthToZ = this.value(this.fields, 'widthToZ');
      level.bias = this.value(this.fields, 'bias'); level.meshOrder = this.value(this.fields, 'order'); level.background = this.backgroundMaterial;
      level.layerNumber = this.value(this.fields, 'layer'); level.datatype = this.value(this.fields, 'datatype');
    }
    this.stack = next; this.levelPending = false; this.materialPending = false; this.syncDraft();
  }
  private parsed(): PhysicalLayerStack {
    this.flush(); const result: PhysicalStackParseResult = parsePhysicalLayerStack(this.draft, this.technologyProvider()?.layers);
    if (!result.ok || result.stack === undefined) throw new Error(result.message);
    return result.stack;
  }
  private pickMaterial(index: number): void {
    this.materialIndex = index; const row: PhysicalMaterial | undefined = this.opaque ? undefined : this.stack.materials[index];
    this.materialName = row?.name ?? ''; this.materialColor = row?.color ?? '#327CE8';
    this.relativePermittivity = row?.relativePermittivity === undefined ? '' : `${row.relativePermittivity}`;
    this.conductivity = row?.conductivitySm === undefined ? '' : `${row.conductivitySm}`; this.materialPending = false;
  }
  private chooseMaterial(index: number): void { try { this.flush(); this.pickMaterial(index); } catch (error) { this.status = String(error); } }
  private pickLevel(index: number): void {
    this.levelIndex = index; const row: PhysicalLayerLevel | undefined = this.opaque ? undefined : this.stack.levels[index];
    this.sourceExpression = row?.sourceExpression ?? ''; this.levelName = row?.name ?? ''; this.backgroundMaterial = row?.background ?? false;
    this.levelMaterialIndex = this.opaque ? 0 : Math.max(0, this.stack.materials.findIndex((material: PhysicalMaterial): boolean => material.id === row?.materialId));
    this.fields = row === undefined ? [] : [
      { key: 'layer', label: '输出图层', value: `${row.layerNumber}` }, { key: 'datatype', label: '输出 datatype', value: `${row.datatype}` },
      { key: 'zmin', label: `底部高度 (${this.stack.unit})`, value: `${row.zmin}` }, { key: 'thickness', label: `厚度 (${this.stack.unit})`, value: `${row.thickness}` },
      { key: 'sidewall', label: '侧壁角 (相对法线，0° 垂直)', value: `${row.sidewallAngleDeg}` }, { key: 'widthToZ', label: '参考宽度高度比例 (0—1)', value: `${row.widthToZ}` },
      { key: 'bias', label: `横向偏置 (${this.stack.unit})`, value: `${row.bias}` }, { key: 'order', label: '材料优先级 (小值优先)', value: `${row.meshOrder}` }
    ]; this.levelPending = false;
  }
  private chooseLevel(index: number): void { try { this.flush(); this.pickLevel(index); } catch (error) { this.status = String(error); } }
  private addMaterial(): void {
    try {
      this.flush(); if (this.opaque || this.stack.materials.length >= 256) throw new Error('材料格式或数量不支持添加');
      const next: PhysicalLayerStack = cloneStructured(this.stack) as PhysicalLayerStack;
      next.materials.push({ id: `material-${Date.now()}`, name: '用户材料', color: '#327CE8' });
      this.stack = next; this.invalidate(); this.syncDraft(); this.pickMaterial(next.materials.length - 1);
      this.status = '已添加材料，请核对层定义与实际厚度，并重新生成几何';
    } catch (error) { this.status = String(error); }
  }
  private addLevel(): void {
    try {
      this.flush(); const pair = this.technologyProvider()?.layers[0];
      if (this.opaque || pair === undefined || !this.stack.materials.length || this.stack.levels.length >= 256) throw new Error('先绑定工艺并添加材料');
      const next: PhysicalLayerStack = cloneStructured(this.stack) as PhysicalLayerStack;
      next.levels.push({ id: `level-${Date.now()}`, name: '用户物理层', layerNumber: pair.layerNumber, datatype: pair.datatype,
        sourceExpression: `${pair.layerNumber}/${pair.datatype}`, materialId: next.materials[this.materialIndex]?.id ?? next.materials[0].id,
        zmin: 0, thickness: 0, sidewallAngleDeg: 0, widthToZ: 0, bias: 0, meshOrder: next.levels.length + 1, background: false });
      this.stack = next; this.invalidate(); this.syncDraft(); this.pickLevel(next.levels.length - 1); this.status = '新增层尚未填写厚度，请输入实际工艺参数';
    } catch (error) { this.status = String(error); }
  }
  private removeLevel(): void {
    try { this.flush(); const next: PhysicalLayerStack = cloneStructured(this.stack) as PhysicalLayerStack;
      const id: string = next.levels[this.levelIndex]?.id ?? ''; if (next.processes.some((step): boolean => step.targetLevelIds.includes(id))) throw new Error('该层仍被工艺步骤引用，请先调整步骤');
      next.levels.splice(this.levelIndex, 1); this.stack = next; this.invalidate(); this.syncDraft(); this.pickLevel(0);
    } catch (error) { this.status = String(error); }
  }
  private options(): LayerStackBuildOptions {
    return { precisionNm: this.value(this.geometryFields, 'precision'), boundsNm: { minX: this.value(this.geometryFields, 'minX'), maxX: this.value(this.geometryFields, 'maxX'), minY: this.value(this.geometryFields, 'minY'), maxY: this.value(this.geometryFields, 'maxY') },
      sectionLine: { startNm: { x: this.value(this.geometryFields, 'sx'), y: this.value(this.geometryFields, 'sy') }, endNm: { x: this.value(this.geometryFields, 'ex'), y: this.value(this.geometryFields, 'ey') } }, coordinatePolicy: this.quantize ? 'quantize' : 'strict' };
  }
  private inputSeal(): string { return JSON.stringify({ draft: this.draft, fields: this.geometryFields, quantize: this.quantize }); }
  private generate(): void {
    if (this.busy) return; this.invalidate(); this.busy = true;
    try {
      if (!this.matches()) throw new Error('文档已变化，请重新打开层栈');
      const stack: PhysicalLayerStack = this.parsed(); if (this.opaque) throw new Error('未知层栈不能执行');
      const seal: string = this.inputSeal(), context: string = this.contextProvider();
      const result: LayerStackResult = this.buildAction(stack, this.options());
      if (!this.matches() || context !== this.contextProvider() || seal !== this.inputSeal()) throw new Error('计算期间文档或参数发生变化，旧几何已丢弃');
      if (!result.ok || result.preview === undefined) throw new Error(result.message);
      this.preview = cloneStructured(result.preview) as LayerStackPreview; this.previewGeometrySeal = JSON.stringify(this.preview);
      this.previewContext = context; this.previewInput = seal; this.status = result.message;
    } catch (error) { this.status = String(error); } finally { this.busy = false; }
  }
  private save(): void {
    if (this.busy) return;
    try { if (!this.matches()) throw new Error('文档已变化，请重新打开层栈'); const stack: PhysicalLayerStack = this.parsed(); this.saveAction(stack);
      this.openedContext = this.contextProvider(); this.invalidate(); this.status = '层栈已保存到当前文档工艺包，可一次撤销';
    } catch (error) { this.status = String(error); }
  }
  private canExport(): boolean { return this.active && this.preview !== undefined && this.previewGeometrySeal === JSON.stringify(this.preview) && this.previewContext === this.contextProvider() && this.previewInput === this.inputSeal() && !this.levelPending && !this.materialPending && !this.jsonPending; }
  private async exportGeometry(kind: string): Promise<void> {
    if (this.busy) return;
    if (!this.canExport()) { this.invalidate(); this.status = '预览已变化或失效，请重新生成完整几何后导出'; return; }
    this.busy = true;
    try {
      const result: LayerStackPreview = this.preview as LayerStackPreview;
      const text: string = kind === 'obj' ? layerStackExportService.obj(result) : kind === 'section' ? layerStackExportService.sectionJson(result) : layerStackExportService.geometryJson(result);
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await engineeringFileService.saveText(context, `physical-stack.${kind === 'obj' ? 'obj' : kind === 'section' ? 'section.json' : 'geometry.json'}`, text,
        () => this.canExport() && this.preview === result, kind === 'obj' ? '三维网格|.obj' : 'JSON 文件|.json');
      if (this.active) this.status = '实际几何已导出（坐标单位 nm）';
    } catch (error) { if (this.active) this.status = String(error); } finally { this.busy = false; }
  }
  @Builder private editor() {
    Column({ space: 12 }) {
      Text(`层栈单位：${this.stack.unit ?? 'nm'}`).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      if (!this.opaque) {
        Row({ space: 8 }) {
          Text('材料').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
          Button('添加材料', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy && !this.jsonPending).onClick(() => this.addMaterial())
        }.width('100%')
        if (this.stack.materials.length) {
          Select(this.stack.materials.map((row: PhysicalMaterial): SelectOption => ({ value: `${row.name} (${row.id})` }))).selected(this.materialIndex).value(this.stack.materials[this.materialIndex]?.name ?? '')
            .height(UI.fieldHeight).width('100%').borderRadius(UI.controlRadius).enabled(!this.busy && !this.jsonPending).onSelect((index: number) => this.chooseMaterial(index))
          GeometryNumberField({ label: '材料名称', value: this.materialName, inputAllowed: !this.busy && !this.jsonPending, onValueChange: (value: string) => { this.materialName = value; this.materialPending = true; this.invalidate(); } })
          GeometryNumberField({ label: '材料颜色 (#RRGGBB)', value: this.materialColor, inputAllowed: !this.busy && !this.jsonPending, onValueChange: (value: string) => { this.materialColor = value; this.materialPending = true; this.invalidate(); } })
          GeometryNumberField({ label: '相对介电常数 (可留空)', value: this.relativePermittivity, inputAllowed: !this.busy && !this.jsonPending, onValueChange: (value: string) => { this.relativePermittivity = value; this.materialPending = true; this.invalidate(); } })
          GeometryNumberField({ label: '电导率 S/m (可留空)', value: this.conductivity, inputAllowed: !this.busy && !this.jsonPending, onValueChange: (value: string) => { this.conductivity = value; this.materialPending = true; this.invalidate(); } })
        }
        Row({ space: 8 }) {
          Text('层定义').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
          Button('添加层', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy && !this.jsonPending).onClick(() => this.addLevel())
          Button('删除层', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy && !this.jsonPending && this.stack.levels.length > 0).onClick(() => this.removeLevel())
        }.width('100%')
        if (this.stack.levels.length) {
          Select(this.stack.levels.map((row: PhysicalLayerLevel): SelectOption => ({ value: `${row.name} · ${row.layerNumber}/${row.datatype}` }))).selected(this.levelIndex).value(this.stack.levels[this.levelIndex]?.name ?? '')
            .height(UI.fieldHeight).width('100%').borderRadius(UI.controlRadius).enabled(!this.busy && !this.jsonPending).onSelect((index: number) => this.chooseLevel(index))
          GeometryNumberField({ label: '层名称', value: this.levelName, inputAllowed: !this.busy && !this.jsonPending, onValueChange: (value: string) => { this.levelName = value; this.levelPending = true; this.invalidate(); } })
          GeometryNumberField({ label: '源区域 (如 1/0 - 2/0，支持括号 | & ^)', value: this.sourceExpression, inputAllowed: !this.busy && !this.jsonPending, onValueChange: (value: string) => { this.sourceExpression = value; this.levelPending = true; this.invalidate(); } })
          Select(this.stack.materials.map((row: PhysicalMaterial): SelectOption => ({ value: row.name }))).selected(this.levelMaterialIndex).value(this.stack.materials[this.levelMaterialIndex]?.name ?? '')
            .height(UI.fieldHeight).width('100%').borderRadius(UI.controlRadius).enabled(!this.busy && !this.jsonPending).onSelect((index: number) => { this.levelMaterialIndex = index; this.levelPending = true; this.invalidate(); })
          ForEach(this.fields, (field: StackFormField) => {
            GeometryNumberField({ label: field.label, value: field.value, inputAllowed: !this.busy && !this.jsonPending, onValueChange: (value: string) => this.setField(field.key, value, false) })
          }, (field: StackFormField): string => field.key)
          SettingsToggleRow({
            title: '背景材料（按 ROI 与排除区域执行）',
            isOn: this.backgroundMaterial,
            enabledState: !this.busy && !this.jsonPending,
            compact: true,
            onToggle: (value: boolean) => { this.backgroundMaterial = value; this.levelPending = true; this.invalidate(); }
          })
        }
      }
      Button(this.advanced ? '收起完整层栈 JSON' : '完整层栈与工艺步骤 JSON', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).width('100%').enabled(!this.busy).onClick(() => {
        try { this.flush(); this.advanced = !this.advanced; } catch (error) { this.status = String(error); }
      })
      if (this.advanced || this.opaque) {
        TextArea({ text: this.draft }).width('100%').height(280).fontSize(UI.fontCaption).fontFamily('monospace')
          .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => { this.draft = value; this.jsonPending = true; this.invalidate(); })
        Button('检查并载入 JSON', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy).onClick(() => {
          try { this.parsed(); this.status = this.opaque ? '未知格式已保留，不能生成几何' : '完整层栈校验通过'; } catch (error) { this.status = String(error); }
        })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  @Builder private geometry() {
    Column({ space: 12 }) {
      Select([{ value: '实际材料截面' }, { value: '实际三维网格' }]).selected(this.mode).value(this.mode === 0 ? '实际材料截面' : '实际三维网格')
        .height(UI.fieldHeight).width('100%').borderRadius(UI.controlRadius).onSelect((index: number) => { this.mode = index; })
      LayerStackGeometryPanel({ preview: this.preview, mode: this.mode })
      ForEach(this.geometryFields, (field: StackFormField) => {
        GeometryNumberField({ label: field.label, value: field.value, inputAllowed: !this.busy, onValueChange: (value: string) => this.setField(field.key, value, true) })
      }, (field: StackFormField): string => field.key)
      SettingsToggleRow({
        title: '允许源 XY 按模型精度量化（退化几何仍拒绝）',
        isOn: this.quantize,
        enabledState: !this.busy,
        compact: true,
        onToggle: (value: boolean) => { this.quantize = value; this.invalidate(); }
      })
      if (this.preview !== undefined) {
        Text(`体积 ${this.preview.totalVolumeNm3} nm³ · ${this.preview.meshes.reduce((sum: number, mesh): number => sum + mesh.triangles.length, 0)} 三角形 · XY 精度 ${this.preview.precisionNm} nm`)
          .fontSize(UI.fontCaption).fontColor(COLORS.ink).width('100%')
        ForEach(this.preview.warnings, (warning: string) => { Text(warning).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%') })
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('导出 OBJ', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 8 }).enabled(!this.busy && this.preview !== undefined).onClick(() => { this.exportGeometry('obj'); })
        Button('导出截面 JSON', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 8 }).enabled(!this.busy && this.preview !== undefined).onClick(() => { this.exportGeometry('section'); })
        Button('导出完整几何', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ bottom: 8 }).enabled(!this.busy && this.preview !== undefined).onClick(() => { this.exportGeometry('geometry'); })
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({ space: 12 }) {
      PanelHeading({ title: '物理层栈', canClose: !this.busy, closeAction: () => this.closeAction() })
      if (this.panelWidth >= 760) {
        Row({ space: 16 }) {
          Scroll() { this.editor() }.width('43%').height('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
          Scroll() { this.geometry() }.layoutWeight(1).height('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
        }.layoutWeight(1).width('100%')
      } else {
        Scroll() { Column({ space: 20 }) { this.editor(); this.geometry(); }.width('100%') }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      }
      if (this.status.length > 0) {
        Text(this.status).fontSize(UI.fontCaption).fontColor(COLORS.accent).width('100%').maxLines(2)
      }
      Row({ space: 10 }) {
        Button('保存到工艺包', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).enabled(!this.busy).onClick(() => this.save())
        Button('生成几何', { type: ButtonType.Normal }).stackButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).backgroundColor(COLORS.primary).fontColor(Color.White).enabled(!this.busy && !this.opaque).onClick(() => this.generate())
      }.width('100%').padding({ top: 12 }).border({ width: { top: 1 }, color: COLORS.border })
    }.width(this.panelWidth).height(this.panelHeight).padding(UI.panelPadding)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay')))
  }
}
@Extend(Button)
function stackButton() {
  .height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).padding({ left: 12, right: 12 })
    .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).hoverEffect(HoverEffect.Highlight)
}
