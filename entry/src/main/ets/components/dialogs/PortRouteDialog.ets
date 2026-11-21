import { hongTuThemeState } from '../../store/ThemeStore';
import { SettingsToggleRow } from '../SettingsKit';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { TechnologyPackage } from '../../common/technologyPackage';
import { Shape, Point } from '../../models/GdsiiData';
import { PortEndpoint, ResolvedPort } from '../../models/LayoutPort';
import { PortUiChoice, PortChoiceQuery } from '../../models/PortUiChoice';
import { RouteMaterialDescriptor, RouteMaterialStrip, RouteTransitionRule, RouteViaRule } from '../../models/RouteMaterial';
import { PlannedRoute } from '../../services/RoutePlannerService';
import { RouteSessionRequest, RouteSessionPair, RouteSessionPreview, RouteSessionResult } from '../../services/RouteSessionService';
import { GeometryNumberField } from './GeometryNumberField';
import { RouteGeometryPanel } from './RouteGeometryPanel';
import { clonePortEndpointModel, cloneStructured } from '../../common/CloneUtils';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

interface RouteFormField { key: string; label: string; value: string; }
interface RoutePairSelection { key: string; label: string; start: PortEndpoint; end: PortEndpoint; waypointsNm: Point[]; }
interface RouteAuxiliaryStrip { id: string; layerNumber: number; datatype: number; widthNm: number; offsetNm: number; }
interface RouteFieldsBuilderParams { fields: RouteFormField[]; group: string; }

@CustomDialog
export struct PortRouteDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  contextProvider: () => string = () => '';
  choicesProvider: (options?: PortChoiceQuery) => PortUiChoice[] = (_options?: PortChoiceQuery) => [];
  scopeNoticeProvider: () => string = () => '';
  technologyProvider: () => TechnologyPackage | undefined = () => undefined;
  resolveAction: (endpoint: PortEndpoint) => ResolvedPort = (_endpoint: PortEndpoint) => { throw new Error('端口未就绪'); };
  prepareAction: (request: RouteSessionRequest) => RouteSessionResult = (_request: RouteSessionRequest) => ({ ok:false, message:'布线未就绪' });
  previewAction: (id: string) => RouteSessionPreview | undefined = (_id: string) => undefined;
  applyAction: (id: string) => RouteSessionResult = (_id: string) => ({ ok:false, message:'布线未就绪' });
  cancelAction: (id?: string) => void = (_id?: string) => {};
  private openedContext: string = '';
  private previewId: string = '';
  private sourceNotice: string = '';
  private targetNotice: string = '';
  private nextPair: number = 1;
  private nextStrip: number = 1;
  @State sourceChoices: PortUiChoice[] = [];
  @State targetChoices: PortUiChoice[] = [];
  @State sourceQuery: string = '';
  @State targetQuery: string = '';
  @State sourceIndex: number = 0;
  @State targetIndex: number = 0;
  @State sourceRow: string = '0';
  @State sourceCol: string = '0';
  @State targetRow: string = '0';
  @State targetCol: string = '0';
  @State pairs: RoutePairSelection[] = [];
  @State waypointPairIndex: number = 0;
  @State waypointX: string = '0';
  @State waypointY: string = '0';
  @State strips: RouteAuxiliaryStrip[] = [];
  @State routeFields: RouteFormField[] = [
    {key:'clearance',label:'障碍净距 (nm)',value:'200'}, {key:'separation',label:'束线净距 (nm)',value:'200'},
    {key:'lead',label:'端口引出长度 (nm)',value:'600'}, {key:'grid',label:'搜索网格 (nm)',value:'100'},
    {key:'minX',label:'范围 X 最小值 (nm)',value:'-10000'}, {key:'maxX',label:'范围 X 最大值 (nm)',value:'10000'},
    {key:'minY',label:'范围 Y 最小值 (nm)',value:'-10000'}, {key:'maxY',label:'范围 Y 最大值 (nm)',value:'10000'},
    {key:'targetLength',label:'目标长度 (nm)',value:''}, {key:'tolerance',label:'长度容差 (nm)',value:'0'}
  ];
  @State auxiliaryFields: RouteFormField[] = [
    {key:'layer',label:'辅助材料图层',value:'2'}, {key:'datatype',label:'辅助材料 datatype',value:'0'},
    {key:'width',label:'辅助材料宽度 (nm)',value:'600'}, {key:'offset',label:'向布线左侧偏移 (nm)',value:'0'}
  ];
  @State taperFields: RouteFormField[] = [
    {key:'minimumLength',label:'渐变最小长度 (nm)',value:'1000'}, {key:'maximumSlope',label:'最大单边斜率',value:'0.1'}
  ];
  @State viaFields: RouteFormField[] = [
    {key:'station',label:'过孔距起点的中心线长度 (nm)',value:'1000'},
    {key:'cutWidth',label:'孔宽 (nm)',value:'200'}, {key:'cutHeight',label:'孔高 (nm)',value:'200'},
    {key:'columns',label:'孔列数',value:'1'}, {key:'rows',label:'孔行数',value:'1'},
    {key:'gapX',label:'孔水平间距 (nm)',value:'200'}, {key:'gapY',label:'孔垂直间距 (nm)',value:'200'},
    {key:'lowerX',label:'下层水平包围 (nm)',value:'100'}, {key:'lowerY',label:'下层垂直包围 (nm)',value:'100'},
    {key:'upperX',label:'上层水平包围 (nm)',value:'100'}, {key:'upperY',label:'上层垂直包围 (nm)',value:'100'}
  ];
  @State transitionIndex: number = 0;
  @State viaIndex: number = 0;
  @State matchLengths: boolean = false;
  @State quantizeInterior: boolean = false;
  @State opticalIndex: number = 0;
  @State opticalPolicyIndex: number = 1;
  @State opticalFields: RouteFormField[] = [
    {key:'radius',label:'最小弯曲半径 (nm)',value:''},
    {key:'fraction',label:'Euler 转角比例 (0—1)',value:'0.5'},
    {key:'deviation',label:'最大材料边界偏差 (nm)',value:'2'},
    {key:'centerError',label:'端面中心容差 (nm)',value:''},
    {key:'angleError',label:'端面角度容差 (°)',value:''},
    {key:'widthError',label:'端面宽度容差 (nm)',value:''}
  ];
  @State technology: TechnologyPackage | undefined = undefined;
  @State candidateShapes: Shape[] = [];
  @State candidatePorts: ResolvedPort[] = [];
  @State candidateRoutes: PlannedRoute[] = [];
  @State summary: string = '';
  @State status: string = '';
  @State scopeNotice: string = '';
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State contentWidth: number = 820;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.invalidate(); this.openedContext = this.contextProvider(); this.pairs = []; this.strips = [];
    this.nextPair = 1; this.nextStrip = 1; this.technology = this.technologyProvider();
    this.searchSource(''); this.searchTarget(''); this.autoBounds();
    this.status = '';
  }
  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0; this.invalidate(); }
  private invalidate(): void {
    if (this.previewId.length) this.cancelAction(this.previewId);
    this.previewId = ''; this.ready = false; this.candidateShapes = []; this.candidateRoutes = []; this.summary = '';
  }
  private changed(): void { this.invalidate(); this.status = '端点或参数已变化，请更新预览'; }
  private matches(): boolean { try { return !!this.openedContext && this.openedContext === this.contextProvider(); } catch (_) { return false; } }
  private updateNotices(): void { this.scopeNotice = [this.sourceNotice,this.targetNotice].filter((s: string): boolean => !!s).join('；'); }
  private searchSource(value: string): void {
    if (this.busy) return; this.changed(); this.sourceQuery = value;
    try { this.sourceChoices = this.choicesProvider({scope:'all',query:value}); this.sourceNotice = this.scopeNoticeProvider(); }
    catch (error) { this.sourceChoices = []; this.sourceNotice = `起点检索失败：${String(error)}`; }
    this.pickSource(0); this.updateNotices();
  }
  private searchTarget(value: string): void {
    if (this.busy) return; this.changed(); this.targetQuery = value;
    try { this.targetChoices = this.choicesProvider({scope:'all',query:value}); this.targetNotice = this.scopeNoticeProvider(); }
    catch (error) { this.targetChoices = []; this.targetNotice = `终点检索失败：${String(error)}`; }
    this.pickTarget(this.targetChoices.length > 1 ? 1 : 0); this.updateNotices();
  }
  private pickSource(index: number): void {
    this.changed(); this.sourceIndex = index; const path = this.sourceChoices[index]?.endpoint.path;
    this.sourceRow = `${path?.length ? path[path.length-1].row : 0}`; this.sourceCol = `${path?.length ? path[path.length-1].col : 0}`;
    this.showPorts();
  }
  private pickTarget(index: number): void {
    this.changed(); this.targetIndex = index; const path = this.targetChoices[index]?.endpoint.path;
    this.targetRow = `${path?.length ? path[path.length-1].row : 0}`; this.targetCol = `${path?.length ? path[path.length-1].col : 0}`;
    this.showPorts();
  }
  private endpoint(choice: PortUiChoice | undefined, row: string, col: string): PortEndpoint {
    if (choice === undefined) throw new Error('请选择真实起点与终点');
    const endpoint: PortEndpoint = clonePortEndpointModel(choice.endpoint) as PortEndpoint;
    if (endpoint.path.length) {
      if (!/^\d+$/.test(row.trim()) || !/^\d+$/.test(col.trim()) || !Number.isSafeInteger(Number(row)) || !Number.isSafeInteger(Number(col))) throw new Error('阵列行列须为从零开始的整数');
      endpoint.path[endpoint.path.length-1].row = Number(row); endpoint.path[endpoint.path.length-1].col = Number(col);
    }
    return endpoint;
  }
  private source(): PortEndpoint { return this.endpoint(this.sourceChoices[this.sourceIndex],this.sourceRow,this.sourceCol); }
  private target(): PortEndpoint { return this.endpoint(this.targetChoices[this.targetIndex],this.targetRow,this.targetCol); }
  private showPorts(): void {
    try { this.candidatePorts = [this.resolveAction(this.source()),this.resolveAction(this.target())]; }
    catch (_) { this.candidatePorts = []; }
  }
  private addPair(): void {
    if (this.busy) return;
    try {
      const start: PortEndpoint = this.source(), end: PortEndpoint = this.target();
      const a: ResolvedPort = this.resolveAction(start), b: ResolvedPort = this.resolveAction(end);
      if (JSON.stringify(start) === JSON.stringify(end)) throw new Error('起点和终点不能是同一端口');
      if (this.pairs.length >= 32) throw new Error('一次最多规划 32 对端口');
      this.changed(); this.pairs = this.pairs.concat([{key:`pair-${this.nextPair++}`,label:`${a.definition.name} → ${b.definition.name}`,start:start,end:end,waypointsNm:[]}]);
      this.status = `已添加 ${this.pairs.length} 对；中心、方向、宽度和具体路径在预览时重新核对`;
    } catch (error) { this.status = String(error); }
  }
  private removePair(key: string): void { this.changed(); this.pairs = this.pairs.filter((p: RoutePairSelection): boolean => p.key !== key); this.waypointPairIndex = Math.min(this.waypointPairIndex,Math.max(0,this.pairs.length-1)); }
  private addWaypoint(): void {
    try {
      const pair: RoutePairSelection | undefined = this.pairs[this.waypointPairIndex]; if (pair === undefined) throw new Error('先添加端口配对');
      const fields: RouteFormField[] = [{key:'x',label:'X',value:this.waypointX},{key:'y',label:'Y',value:this.waypointY}];
      const point: Point = {x:this.value(fields,'x'),y:this.value(fields,'y')};
      if (pair.waypointsNm.length >= 32) throw new Error('每对最多添加 32 个途经点');
      this.changed(); this.pairs = this.pairs.map((p: RoutePairSelection): RoutePairSelection => ({key:p.key,label:p.label,start:p.start,end:p.end,waypointsNm:p.key===pair.key?p.waypointsNm.concat([point]):p.waypointsNm}));
    } catch (error) { this.status = String(error); }
  }
  private removeWaypoint(index: number): void {
    const pair: RoutePairSelection | undefined = this.pairs[this.waypointPairIndex]; if (pair === undefined) return;
    this.changed(); this.pairs = this.pairs.map((p: RoutePairSelection): RoutePairSelection => ({key:p.key,label:p.label,start:p.start,end:p.end,waypointsNm:p.key===pair.key?p.waypointsNm.filter((_point: Point,i: number): boolean => i!==index):p.waypointsNm}));
  }
  private value(fields: RouteFormField[], key: string): number {
    const field: RouteFormField | undefined = fields.find((f: RouteFormField): boolean => f.key === key);
    const text: string = field?.value.trim() ?? '';
    if (!/^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/.test(text) || !Number.isFinite(Number(text))) throw new Error('请填写有限数值：'+(field?.label ?? '布线参数'));
    return Number(text);
  }
  private changeField(group: string, key: string, value: string): void {
    if (this.busy) return; this.changed();
    const fields: RouteFormField[] = group === 'optical' ? this.opticalFields : group === 'via' ? this.viaFields : group === 'taper' ? this.taperFields : group === 'auxiliary' ? this.auxiliaryFields : this.routeFields;
    const next: RouteFormField[] = fields.map((f: RouteFormField): RouteFormField => ({key:f.key,label:f.label,value:f.key===key?value:f.value}));
    if (group === 'optical') this.opticalFields = next; else if (group === 'via') this.viaFields = next; else if (group === 'taper') this.taperFields = next; else if (group === 'auxiliary') this.auxiliaryFields = next; else this.routeFields = next;
  }
  private autoBounds(): void {
    if (this.busy) return;
    try {
      const ports: ResolvedPort[] = this.pairs.length ? this.pairs.flatMap((pair: RoutePairSelection): ResolvedPort[] => [this.resolveAction(pair.start),this.resolveAction(pair.end)]) : [this.resolveAction(this.source()),this.resolveAction(this.target())];
      const margin: number = Math.max(2000,this.value(this.routeFields,'lead')+this.value(this.routeFields,'clearance')+Math.max(...ports.map((p: ResolvedPort): number => p.effectiveWidthNm)));
      this.changed(); this.routeFields = this.routeFields.map((f: RouteFormField): RouteFormField => ({key:f.key,label:f.label,value:
        f.key==='minX' ? `${Math.min(...ports.map((p: ResolvedPort): number => p.centerNm.x))-margin}` :
        f.key==='maxX' ? `${Math.max(...ports.map((p: ResolvedPort): number => p.centerNm.x))+margin}` :
        f.key==='minY' ? `${Math.min(...ports.map((p: ResolvedPort): number => p.centerNm.y))-margin}` :
        f.key==='maxY' ? `${Math.max(...ports.map((p: ResolvedPort): number => p.centerNm.y))+margin}` : f.value}));
    } catch (error) { this.status = `范围未更新：${String(error)}`; }
  }
  private addStrip(): void {
    try {
      const layer: number = this.value(this.auxiliaryFields,'layer'), datatype: number = this.value(this.auxiliaryFields,'datatype');
      const width: number = this.value(this.auxiliaryFields,'width'), offset: number = this.value(this.auxiliaryFields,'offset');
      if (!Number.isInteger(layer) || layer < 0 || layer > 32767 || !Number.isInteger(datatype) || datatype < 0 || datatype > 32767 || width <= 0 || this.strips.length >= 63) throw new Error('辅助材料参数或数量无效');
      this.changed(); this.strips = this.strips.concat([{id:`strip-${this.nextStrip++}`,layerNumber:layer,datatype:datatype,widthNm:width,offsetNm:offset}]);
    } catch (error) { this.status = String(error); }
  }
  private descriptor(port: ResolvedPort, start: boolean): string | undefined {
    if (!this.strips.length) return undefined;
    if (port.definition.crossSectionKey !== undefined) throw new Error('端口已有 CrossSection；辅助材料须在其定义中声明，不能覆盖');
    const factor: number = port.frameMagnification*(port.frameMirror?-1:1)*(start?1:-1);
    const strips: RouteMaterialStrip[] = [{id:'main',layerNumber:port.definition.layerNumber,datatype:port.definition.datatype,widthNm:port.definition.widthNm,offsetNm:0}];
    for (const s of this.strips) strips.push({id:s.id,layerNumber:s.layerNumber,datatype:s.datatype,widthNm:s.widthNm/port.frameMagnification,offsetNm:s.offsetNm/factor});
    const descriptor: RouteMaterialDescriptor = {schema:'hongtu-route-material/v1',primaryStripId:'main',strips:strips};
    return JSON.stringify(descriptor);
  }
  private transitionRuleJson(): string | undefined {
    if (this.transitionIndex === 0) return undefined;
    if (this.transitionIndex === 1) {
      const taper: RouteTransitionRule = {schema:'hongtu-route-transition/v1',kind:'linear-taper',minimumLengthNm:this.value(this.taperFields,'minimumLength'),maximumEdgeSlope:this.value(this.taperFields,'maximumSlope')};
      return JSON.stringify(taper);
    }
    const tech: TechnologyPackage | undefined = this.technology;
    const via = tech?.viaLayers[this.viaIndex]; if (tech === undefined || via === undefined) throw new Error('请先绑定声明过孔连通关系的真实工艺');
    const rule: RouteViaRule = {schema:'hongtu-route-transition/v1',kind:'via',technologyId:tech.id,technologyVersion:tech.version,
      lowerLayerNumber:via.lowerLayer,lowerDatatype:via.lowerDatatype ?? 0,upperLayerNumber:via.upperLayer,upperDatatype:via.upperDatatype ?? 0,
      cutLayerNumber:via.viaLayer,cutDatatype:via.viaDatatype ?? 0,stationNm:this.value(this.viaFields,'station'),
      cutWidthNm:this.value(this.viaFields,'cutWidth'),cutHeightNm:this.value(this.viaFields,'cutHeight'),columns:this.value(this.viaFields,'columns'),rows:this.value(this.viaFields,'rows'),
      gapXNm:this.value(this.viaFields,'gapX'),gapYNm:this.value(this.viaFields,'gapY'),lowerEnclosureXNm:this.value(this.viaFields,'lowerX'),lowerEnclosureYNm:this.value(this.viaFields,'lowerY'),
      upperEnclosureXNm:this.value(this.viaFields,'upperX'),upperEnclosureYNm:this.value(this.viaFields,'upperY')};
    return JSON.stringify(rule);
  }
  private request(): RouteSessionRequest {
    if (!this.pairs.length) throw new Error('至少添加一对明确端口');
    const pairs: RouteSessionPair[] = this.pairs.map((p: RoutePairSelection): RouteSessionPair => ({key:p.key,start:p.start,end:p.end,
      waypointsNm:p.waypointsNm,descriptorJson:this.descriptor(this.resolveAction(p.start),true),endDescriptorJson:this.descriptor(this.resolveAction(p.end),false),transitionRuleJson:this.transitionRuleJson()}));
    const target: string = this.routeFields.find((f: RouteFormField): boolean => f.key==='targetLength')?.value.trim() ?? '';
    return {pairs:pairs,boundsNm:{minX:this.value(this.routeFields,'minX'),maxX:this.value(this.routeFields,'maxX'),minY:this.value(this.routeFields,'minY'),maxY:this.value(this.routeFields,'maxY')},
      clearanceNm:this.value(this.routeFields,'clearance'),separationNm:this.value(this.routeFields,'separation'),leadNm:this.value(this.routeFields,'lead'),gridNm:this.value(this.routeFields,'grid'),
      matchLengths:this.matchLengths,targetLengthNm:target.length?this.value(this.routeFields,'targetLength'):undefined,lengthToleranceNm:this.value(this.routeFields,'tolerance'),
      coordinatePolicy:this.quantizeInterior?'quantize-interior':'strict',
      optical: this.opticalIndex === 0 ? undefined : {
        bend: this.opticalIndex === 1 ? 'circular' : this.opticalIndex === 2 ? 'euler' : 's-bend',
        minimumRadiusNm: this.value(this.opticalFields,'radius'), eulerFraction: this.value(this.opticalFields,'fraction'),
        maximumDeviationNm: this.value(this.opticalFields,'deviation'),
        coordinatePolicy: this.opticalPolicyIndex === 0 ? 'strict' : this.opticalPolicyIndex === 1 ? 'quantize-interior' : 'quantize-with-port-tolerance',
        portTolerance: this.opticalPolicyIndex === 2 ? { maximumCenterErrorNm:this.value(this.opticalFields,'centerError'),
          maximumAngleErrorDeg:this.value(this.opticalFields,'angleError'), maximumWidthErrorNm:this.value(this.opticalFields,'widthError') } : undefined
      }};
  }
  private refresh(): void {
    if (this.busy) return; this.invalidate();
    if (!this.matches()) { this.status = '文档、选区或工艺已变化，请重新打开布线'; return; }
    this.busy = true;
    try {
      const result: RouteSessionResult = this.prepareAction(this.request()); this.status = result.message;
      if (result.ok && result.preview !== undefined) {
        this.previewId = result.preview.id;
        const preview: RouteSessionPreview | undefined = this.previewAction(this.previewId);
        if (preview === undefined || !this.matches()) throw new Error('布线预览已失效');
        this.candidateShapes = preview.shapes; this.candidatePorts = preview.ports; this.candidateRoutes = preview.routes;
        const pairs: string[] = [];
        for (const shape of preview.shapes) { const pair: string = `L${shape.layerNumber}/D${shape.datatype}`; if (!pairs.includes(pair)) pairs.push(pair); }
        this.summary = `${preview.routes.length} 条路线 · ${preview.shapes.length} 个材料多边形 · ${preview.obstacleCount} 个完整材料障碍\n${pairs.join(' · ')}\n`+
          preview.lengthDefinition+'\n'+preview.routes.map((r: PlannedRoute): string => `${r.pairKey}: ${r.lengthNm} nm，实际加长 ${r.addedLengthNm} nm`).join('\n')+
          (preview.warnings.length?'\n'+preview.warnings.join('\n'):'');
        this.ready = true;
      }
    } catch (error) { this.invalidate(); this.status = `布线未预览：${String(error)}`; }
    finally { this.busy = false; }
  }
  private apply(): void {
    if (this.busy || !this.ready || !this.previewId) return;
    this.busy = true;
    try {
      if (!this.matches() || this.previewAction(this.previewId) === undefined) { this.invalidate(); this.status = '文档、选区或工艺已变化，请重新打开布线'; return; }
      const result: RouteSessionResult = this.applyAction(this.previewId); this.status = result.message; this.invalidate(); if (result.ok) this.controller.close();
    }
    catch (error) { this.invalidate(); this.status = `布线未应用：${String(error)}`; }
    finally { this.busy = false; }
  }
  private routeFieldText(key: string, fallback: string): string {
    return this.routeFields.find((field: RouteFormField): boolean => field.key === key)?.value ?? fallback;
  }
  @Builder
  Fields(params: RouteFieldsBuilderParams) {
    Column({ space: 8 }) {
      ForEach(params.fields,(field: RouteFormField) => {
        GeometryNumberField({label:field.label,value:params.group === 'route' ? this.routeFieldText(field.key,field.value) : field.value,inputAllowed:!this.busy,onValueChange:(value: string) => this.changeField(params.group,field.key,value)})
      },(field: RouteFormField): string => field.key)
    }.width('100%')
  }
  @Builder
  Optical() {
    Column({ space: 8 }) {
      Text('光学端口曲线').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Select([{value:'未启用光学曲线'},{value:'圆弧'},{value:'Euler 弯曲'},{value:'S 弯'}]).selected(this.opticalIndex)
        .value(['未启用光学曲线','圆弧','Euler 弯曲','S 弯'][this.opticalIndex]).height(UI.fieldHeight).width('100%').borderRadius(UI.controlRadius)
        .enabled(!this.busy).onSelect((index: number) => {this.opticalIndex=index;this.changed();})
      if (this.opticalIndex > 0) {
        this.Fields({ fields: this.opticalFields.filter((field: RouteFormField): boolean => !['centerError','angleError','widthError'].includes(field.key)), group: 'optical' })
        Select([{value:'端面与内点严格 DBU'},{value:'仅内点量化，端面严格 DBU'},{value:'明确端面误差后量化'}]).selected(this.opticalPolicyIndex)
          .value(['端面与内点严格 DBU','仅内点量化，端面严格 DBU','明确端面误差后量化'][this.opticalPolicyIndex]).height(UI.fieldHeight).width('100%').borderRadius(UI.controlRadius)
          .enabled(!this.busy).onSelect((index: number) => {this.opticalPolicyIndex=index;this.changed();})
        if (this.opticalPolicyIndex === 2) {
          this.Fields({ fields: this.opticalFields.filter((field: RouteFormField): boolean => ['centerError','angleError','widthError'].includes(field.key)), group: 'optical' })
        }
      }
    }.width('100%')
  }
  @Builder
  Endpoints() {
    Column({ space: 8 }) {
      Text('起点端口').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Search({ value: this.sourceQuery, placeholder: '搜索起点名称、ID 或具体实例' })
        .defaultFocus(true)
        .onFocus(() => { resetModifierKeys(); })
        .width('100%').height(UI.fieldHeight).textFont({ size: UI.fontBody }).placeholderFont({ size: UI.fontBody })
        .fontColor(COLORS.ink).placeholderColor(COLORS.muted)
        .searchIcon({ size: 16, color: COLORS.muted })
        .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 14, color: COLORS.muted } })
        .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .enabled(!this.busy).onKeyEvent((event: KeyEvent) => event.stopPropagation())
        .onChange((value: string) => this.searchSource(value))
      Select(this.sourceChoices.map((p: PortUiChoice): SelectOption => ({value:p.label}))).selected(this.sourceIndex).value(this.sourceChoices[this.sourceIndex]?.label??'没有起点端口')
        .height(UI.fieldHeight).width('100%').font({size:UI.fontBody}).backgroundColor(COLORS.surfaceMuted).border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy).onSelect((index: number) => this.pickSource(index))
      Row({space:8}) {
        GeometryNumberField({label:'起点阵列行（从 0 开始）',value:this.sourceRow,inputAllowed:!this.busy&&(this.sourceChoices[this.sourceIndex]?.endpoint.path.length??0)>0,onValueChange:(value: string) => {this.sourceRow=value;this.changed();this.showPorts();}}).layoutWeight(1)
        GeometryNumberField({label:'起点阵列列（从 0 开始）',value:this.sourceCol,inputAllowed:!this.busy&&(this.sourceChoices[this.sourceIndex]?.endpoint.path.length??0)>0,onValueChange:(value: string) => {this.sourceCol=value;this.changed();this.showPorts();}}).layoutWeight(1)
      }.width('100%')
      Text('终点端口').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Search({ value: this.targetQuery, placeholder: '搜索终点名称、ID 或具体实例' })
        .onFocus(() => { resetModifierKeys(); })
        .width('100%').height(UI.fieldHeight).textFont({ size: UI.fontBody }).placeholderFont({ size: UI.fontBody })
        .fontColor(COLORS.ink).placeholderColor(COLORS.muted)
        .searchIcon({ size: 16, color: COLORS.muted })
        .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 14, color: COLORS.muted } })
        .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .enabled(!this.busy).onKeyEvent((event: KeyEvent) => event.stopPropagation())
        .onChange((value: string) => this.searchTarget(value))
      Select(this.targetChoices.map((p: PortUiChoice): SelectOption => ({value:p.label}))).selected(this.targetIndex).value(this.targetChoices[this.targetIndex]?.label??'没有终点端口')
        .height(UI.fieldHeight).width('100%').font({size:UI.fontBody}).backgroundColor(COLORS.surfaceMuted).border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy).onSelect((index: number) => this.pickTarget(index))
      Row({space:8}) {
        GeometryNumberField({label:'终点阵列行（从 0 开始）',value:this.targetRow,inputAllowed:!this.busy&&(this.targetChoices[this.targetIndex]?.endpoint.path.length??0)>0,onValueChange:(value: string) => {this.targetRow=value;this.changed();this.showPorts();}}).layoutWeight(1)
        GeometryNumberField({label:'终点阵列列（从 0 开始）',value:this.targetCol,inputAllowed:!this.busy&&(this.targetChoices[this.targetIndex]?.endpoint.path.length??0)>0,onValueChange:(value: string) => {this.targetCol=value;this.changed();this.showPorts();}}).layoutWeight(1)
      }.width('100%')
      Button('添加端口配对',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
        .border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy&&this.sourceChoices.length>0&&this.targetChoices.length>0).onClick(() => this.addPair())
      ForEach(this.pairs,(pair: RoutePairSelection) => {
        Row({space:8}) {
          Text(`${pair.key} · ${pair.label}`).fontSize(UI.fontCaption).fontColor(COLORS.ink).layoutWeight(1)
          Button('移除',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.danger).backgroundColor(COLORS.dangerSoft)
            .border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => this.removePair(pair.key))
        }.width('100%')
      },(pair: RoutePairSelection): string => pair.key)
      if (this.pairs.length) {
        Text(this.opticalIndex > 0 ? '角控制点' : '途经点').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
        Select(this.pairs.map((p: RoutePairSelection): SelectOption => ({value:`${p.key} · ${p.label}`}))).selected(this.waypointPairIndex).value(this.pairs[this.waypointPairIndex]?.label??'选择配对')
          .height(UI.fieldHeight).width('100%').font({size:UI.fontBody}).backgroundColor(COLORS.surfaceMuted).border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy)
          .onSelect((index: number) => {this.waypointPairIndex=index;})
        Row({space:8}) {
          GeometryNumberField({label:'途经点 X (nm)',value:this.waypointX,inputAllowed:!this.busy,onValueChange:(value: string) => {this.waypointX=value;}}).layoutWeight(1)
          GeometryNumberField({label:'途经点 Y (nm)',value:this.waypointY,inputAllowed:!this.busy,onValueChange:(value: string) => {this.waypointY=value;}}).layoutWeight(1)
        }.width('100%')
        Button('添加途经点',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
          .border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => this.addWaypoint())
        ForEach(this.pairs[this.waypointPairIndex]?.waypointsNm??[],(point: Point,index: number) => {
          Row({space:8}) {
            Text(`${index+1}: ${point.x}, ${point.y} nm`).fontSize(UI.fontCaption).fontColor(COLORS.ink).layoutWeight(1)
            Button('移除',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.danger).backgroundColor(COLORS.dangerSoft)
              .border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => this.removeWaypoint(index))
          }.width('100%')
        },(_point: Point,index: number): string => `${this.pairs[this.waypointPairIndex]?.key}:${index}`)
      }
    }.width('100%').padding({ right: 2 }).alignItems(HorizontalAlign.Start)
  }
  @Builder
  Parameters() {
    Column({space:12}) {
      Text('布线范围与净距').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Button('按端点更新范围',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
        .border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => this.autoBounds())
      this.Fields({ fields: this.routeFields, group: 'route' })
      this.Optical()
      SettingsToggleRow({
        title: '以实际蛇形几何匹配长度',
        isOn: this.matchLengths,
        enabledState: !this.busy,
        compact: true,
        onToggle: (value: boolean) => { this.matchLengths = value; this.changed(); }
      })
      SettingsToggleRow({
        title: '允许内部轮廓量化到 DBU（端面保持精确）',
        isOn: this.quantizeInterior,
        enabledState: !this.busy,
        compact: true,
        onToggle: (value: boolean) => { this.quantizeInterior = value; this.changed(); }
      })
      Text('材料与端口过渡').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Select([{value:'相同材料，无过渡'},{value:'明确线性宽度 / 偏移渐变'},{value:'按当前工艺跨层过孔'}]).selected(this.transitionIndex)
        .value(['相同材料，无过渡','明确线性宽度 / 偏移渐变','按当前工艺跨层过孔'][this.transitionIndex]).height(UI.fieldHeight).width('100%').font({size:UI.fontBody})
        .backgroundColor(COLORS.surfaceMuted).border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy).onSelect((index: number) => {this.transitionIndex=index;this.changed();})
      if (this.transitionIndex === 1) { this.Fields({ fields: this.taperFields, group: 'taper' }) }
      if (this.transitionIndex === 2) {
        Text(this.technology===undefined?'未绑定工艺':`${this.technology.name} · ${this.technology.version}`).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
        Select((this.technology?.viaLayers??[]).map((via): SelectOption => ({value:`L${via.lowerLayer}/D${via.lowerDatatype ?? 0} → L${via.upperLayer}/D${via.upperDatatype ?? 0}，孔 L${via.viaLayer}/D${via.viaDatatype ?? 0}`})))
          .selected(this.viaIndex).value((this.technology?.viaLayers??[]).length?'选择工艺过孔连通项':'没有已声明过孔').height(UI.fieldHeight).width('100%').font({size:UI.fontBody})
          .backgroundColor(COLORS.surfaceMuted).border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy&&(this.technology?.viaLayers??[]).length>0).onSelect((index: number) => {this.viaIndex=index;this.changed();})
        this.Fields({ fields: this.viaFields, group: 'via' })
      }
      Text('辅助材料带').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      this.Fields({ fields: this.auxiliaryFields, group: 'auxiliary' })
      Button('添加辅助材料带',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
        .border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => this.addStrip())
      ForEach(this.strips,(strip: RouteAuxiliaryStrip) => {
        Row({space:8}) {
          Text(`L${strip.layerNumber}/D${strip.datatype} · 宽 ${strip.widthNm} nm · 偏移 ${strip.offsetNm} nm`).fontSize(UI.fontCaption).fontColor(COLORS.ink).layoutWeight(1)
          Button('移除',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.danger).backgroundColor(COLORS.dangerSoft)
            .border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => {this.changed();this.strips=this.strips.filter((s: RouteAuxiliaryStrip): boolean => s.id!==strip.id);})
        }.width('100%')
      },(strip: RouteAuxiliaryStrip): string => strip.id)
    }.width('100%').padding({ right: 2 }).alignItems(HorizontalAlign.Start)
  }
  @Builder
  Preview() {
    Column({space:12}) {
      RouteGeometryPanel({shapes:this.candidateShapes,ports:this.candidatePorts,routes:this.candidateRoutes})
      if (this.summary.length > 0) { Text(this.summary).fontSize(UI.fontCaption).fontColor(COLORS.ink).width('100%') }
      if (this.status.length > 0) { Text(this.status).fontSize(UI.fontBody).fontColor(this.ready?COLORS.ink:COLORS.danger).width('100%') }
      if (this.scopeNotice.length > 0) { Text(this.scopeNotice).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%') }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({space:16}) {
      Text('端口布线').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink).width('100%')
      if (this.contentWidth >= 700) {
        Row({space:16}) {
          Scroll() { Column({space:16}) { this.Endpoints(); this.Parameters() }.width('100%').alignItems(HorizontalAlign.Start) }.layoutWeight(1).height('100%').align(Alignment.Top).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
          Scroll() { this.Preview() }.layoutWeight(1).height('100%').align(Alignment.Top).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
        }.width('100%').layoutWeight(1)
      } else {
        Scroll() { Column({space:16}) { this.Endpoints(); this.Parameters(); this.Preview() }.width('100%').alignItems(HorizontalAlign.Start) }.width('100%').layoutWeight(1).align(Alignment.Top).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      }
      Row({space:12}) {
        Button('取消',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
          .border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy).onClick(() => {this.invalidate();this.controller.close();})
        Blank()
        Button('更新预览',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
          .border({width:1,color:COLORS.border}).borderRadius(UI.controlRadius).attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy&&this.pairs.length>0).onClick(() => this.refresh())
        Button('应用布线',{type:ButtonType.Normal}).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(Color.White).backgroundColor(COLORS.primary)
          .border({width:1,color:COLORS.primary}).borderRadius(UI.controlRadius).attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.ready&&!this.busy).onClick(() => this.apply())
      }.width('100%').padding({top:16}).border({width:{top:1},color:COLORS.border})
    }.width(980).height('88%').constraintSize({maxWidth:'94%',maxHeight:820}).padding(UI.dialogPadding)
      .backgroundColor(COLORS.surface).borderRadius(UI.dialogRadius).transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => event.stopPropagation())
      .onAreaChange((_old: Area,area: Area) => {this.contentWidth=Math.max(0,Number(area.width)-2*UI.dialogPadding);})
  }
}
