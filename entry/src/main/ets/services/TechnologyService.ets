import { LayerGroup } from '../common/types';
import type { UiLayer } from '../common/types';
import { parseTechnologyPackage } from '../common/technologyPackage';
import type { TechnologyPackage, TechnologyParseResult, TechnologyDevice } from '../common/technologyPackage';
import { parseRuleSetText } from '../common/drcRuleText';
import type { DrcRule } from '../common/drcRulesets';
import type { NativeViaLayer, PCellInfo } from '../../cpp/types/libhongtu/Index';
import { drcService } from './DrcService';
import type { PhysicalLayerStack } from '../models/PhysicalLayerStack';
import { serializePhysicalLayerStack } from '../models/PhysicalLayerStack';
import { cloneStructured } from '../common/CloneUtils';

interface TechnologyDocumentDeck { name: string; rules: DrcRule[]; }
export interface TechnologyDevicePlacement {
  technologyId: string;
  technologyVersion: string;
  deviceName: string;
  pcell: string;
  model: string;
  parameters: Record<string, number | string | boolean>;
}

export class TechnologyService {
  private active?: TechnologyPackage;

  getActive(): TechnologyPackage | undefined {
    return this.active === undefined ? undefined : cloneStructured(this.active) as TechnologyPackage;
  }
  getViaLayers(): NativeViaLayer[] {
    return this.active === undefined ? [] : this.active.viaLayers.map((v: NativeViaLayer): NativeViaLayer => ({
      viaLayer: v.viaLayer, lowerLayer: v.lowerLayer, upperLayer: v.upperLayer,
      viaDatatype: v.viaDatatype, lowerDatatype: v.lowerDatatype, upperDatatype: v.upperDatatype
    }));
  }
  getDevices(): TechnologyDevice[] { return this.getActive()?.devices ?? []; }
  getLayerStack(): PhysicalLayerStack | undefined { return this.getActive()?.layerStack; }
  /** Validates the complete process before replacing settings; source geometry,
   * active rules and the previous process stay untouched on failure. */
  setLayerStack(stack: PhysicalLayerStack): void {
    const next: TechnologyPackage | undefined = this.getActive();
    if (next === undefined) throw new Error('请先绑定工艺包，再保存物理层栈');
    next.layerStack = JSON.parse(serializePhysicalLayerStack(stack)) as PhysicalLayerStack;
    const checked: TechnologyParseResult = parseTechnologyPackage(JSON.stringify(next));
    if (!checked.ok || checked.technology === undefined) throw new Error(checked.error);
    this.active = checked.technology;
  }

  /** Apply native defaults, then process defaults, then explicit user overrides.
   * Model identity remains metadata; this does not imply foundry device extraction. */
  resolveDevice(name: string, availablePCells: PCellInfo[], overrides: Record<string, number | string | boolean> = {}): TechnologyDevicePlacement {
    const active: TechnologyPackage | undefined = this.active;
    const device: TechnologyDevice | undefined = active?.devices.find((item: TechnologyDevice): boolean => item.name === name);
    if (active === undefined || device === undefined) throw new Error('当前工艺中没有该器件');
    const pcell: PCellInfo | undefined = availablePCells.find((item: PCellInfo): boolean => item.name === device.pcell);
    if (pcell === undefined) throw new Error(`工艺器件需要未安装的 PCell ${device.pcell}`);
    if (overrides === null || typeof overrides !== 'object' || Array.isArray(overrides)) throw new Error('器件参数应为对象');
    const parameters: Record<string, number | string | boolean> = {};
    const overrideKeys: string[] = Object.keys(overrides);
    const processKeys: string[] = Object.keys(device.parameters);
    for (const source of [device.parameters, overrides]) {
      for (const key of Object.keys(source)) {
        if (!pcell.params.some((item): boolean => item.name === key)) throw new Error(`PCell ${device.pcell} 没有参数 ${key}`);
      }
    }
    for (const declaration of pcell.params) {
      const key: string = declaration.name;
      const value: number | string | boolean = overrideKeys.indexOf(key) >= 0 ? overrides[key]
        : processKeys.indexOf(key) >= 0 ? device.parameters[key] : declaration.defaultValue;
      if (declaration.type === 'int' || declaration.type === 'double' || declaration.type === 'layer') {
        if (typeof value !== 'number' || !Number.isFinite(value) ||
          (declaration.type !== 'double' && !Number.isInteger(value)) ||
          (declaration.type === 'layer' && (value < 0 || value > 32767)) ||
          (typeof declaration.minValue === 'number' && value < declaration.minValue) ||
          (typeof declaration.maxValue === 'number' && value > declaration.maxValue)) throw new Error(`工艺器件参数 ${key} 超出 PCell 类型或范围`);
      } else if (declaration.type === 'boolean') {
        if (typeof value !== 'boolean') throw new Error(`工艺器件参数 ${key} 需要布尔值`);
      } else if (typeof value !== 'string' || value.length > 65536 || value.includes('\0')) throw new Error(`工艺器件参数 ${key} 需要文本`);
      parameters[key] = value;
    }
    return { technologyId: active.id, technologyVersion: active.version, deviceName: device.name,
      pcell: device.pcell, model: device.model, parameters: parameters };
  }
  serialize(): string { return this.active === undefined ? '' : JSON.stringify(this.active, null, 2); }
  clear(): void { this.active = undefined; drcService.setRules([], '未绑定工艺'); }

  /** Restore inert settings only after the caller has established session ownership.
   * Both inputs are validated before changing the active process or custom rules. */
  restoreDocumentSettings(technologyJson: string, drcDeckJson: string, currentLayers: UiLayer[]): UiLayer[] {
    let technology: TechnologyPackage | undefined;
    let deck: TechnologyDocumentDeck | undefined;
    if (technologyJson.length > 0) {
      const parsed: TechnologyParseResult = parseTechnologyPackage(technologyJson);
      if (!parsed.ok || parsed.technology === undefined) throw new Error(parsed.error);
      technology = parsed.technology;
    }
    if (drcDeckJson.length > 0) {
      if (drcDeckJson.length > 2 * 1024 * 1024) throw new Error('工程 DRC 规则超过文本预算');
      const incoming: TechnologyDocumentDeck = JSON.parse(drcDeckJson) as TechnologyDocumentDeck;
      if (incoming === null || typeof incoming !== 'object' || typeof incoming.name !== 'string' ||
        incoming.name.length > 256 || !Array.isArray(incoming.rules) || incoming.rules.length > 4096) throw new Error('工程 DRC 规则格式无效');
      if (incoming.rules.length === 0) deck = { name: incoming.name, rules: [] };
      else {
        const parsed = parseRuleSetText(drcDeckJson, true);
        if (!parsed.ok) throw new Error(parsed.error);
        deck = { name: parsed.setName, rules: parsed.rules };
      }
    }
    const layers: UiLayer[] = technology === undefined ? currentLayers : this.activate(technology, currentLayers);
    if (technology === undefined) this.clear();
    if (deck !== undefined) drcService.setRules(deck.rules, deck.name);
    return layers;
  }

  /** Pure candidate mapping for a process structure transaction. */
  // Copy supported JSON layer payloads without sharing nested objects. Runtime
  // own undefined values and sparse indices remain distinct until JSON saving.
  private cloneLayerOwnValue(value: Object | null | undefined): Object | null | undefined {
    if (value === null || typeof value !== 'object') return value;
    if (Array.isArray(value)) {
      const source: (Object | null | undefined)[] = value as (Object | null | undefined)[];
      const copy: (Object | null | undefined)[] = new Array<Object | null | undefined>(source.length);
      const present: Set<string> = new Set<string>(Object.keys(source));
      for (let index: number = 0; index < source.length; index++) {
        if (present.has(String(index))) copy[index] = this.cloneLayerOwnValue(source[index]);
      }
      return copy;
    }
    const source: Record<string, Object | null | undefined> = value as Record<string, Object | null | undefined>;
    const keys: string[] = Object.keys(source);
    const entries: string[] = keys.map((key: string): string => JSON.stringify(key) + ':null');
    // Precreate own data properties, including an inert __proto__ key.
    const copy: Record<string, Object | null | undefined> = JSON.parse('{' + entries.join(',') + '}') as Record<string, Object | null | undefined>;
    for (const key of keys) copy[key] = this.cloneLayerOwnValue(source[key]);
    return copy;
  }

  deriveLayers(technology: TechnologyPackage, currentLayers: UiLayer[]): UiLayer[] {
    const parsed: TechnologyParseResult = parseTechnologyPackage(JSON.stringify(technology));
    if (!parsed.ok || parsed.technology === undefined) throw new Error(parsed.error);
    const next: TechnologyPackage = parsed.technology;
    const layers: UiLayer[] = [];
    for (const source of currentLayers) {
      const mapping = next.layers.find((item) => item.layerNumber === source.layerNumber && item.datatype === source.datatype);
      const layer: UiLayer = this.cloneLayerOwnValue(source) as UiLayer;
      layer.chineseName = mapping?.name ?? source.chineseName;
      layer.englishName = mapping?.name ?? source.englishName;
      layer.color = mapping?.color ?? source.color;
      layers.push(layer);
    }
    for (const mapping of next.layers) {
      if (layers.some((item: UiLayer) => item.layerNumber === mapping.layerNumber && item.datatype === mapping.datatype)) continue;
      layers.push({ layerNumber: mapping.layerNumber, datatype: mapping.datatype,
        chineseName: mapping.name, englishName: mapping.name, color: mapping.color,
        visible: true, locked: false, elementCount: 0,
        group: mapping.purpose === 'cut' ? LayerGroup.CONTACT : LayerGroup.OTHER });
    }
    return layers;
  }
  /** Validate and apply as one operation. Only names/colors change; raw pair IDs never change. */
  activate(technology: TechnologyPackage, currentLayers: UiLayer[]): UiLayer[] {
    const checked: TechnologyParseResult = parseTechnologyPackage(JSON.stringify(technology));
    if (!checked.ok || checked.technology === undefined) throw new Error(checked.error);
    const next: TechnologyPackage = checked.technology;
    const layers: UiLayer[] = this.deriveLayers(next, currentLayers);
    drcService.setRules(next.drcRules, `${next.name} ${next.version} · ${next.qualification}`);
    this.active = next;
    return layers;
  }
}
export const technologyService = new TechnologyService();
