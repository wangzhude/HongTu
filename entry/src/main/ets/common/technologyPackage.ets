import type { DrcRule } from './drcRulesets';
import { RULESET_SKY130_MET1 } from './drcRulesets';
import { parseRuleSetText } from './drcRuleText';
import type { NativeViaLayer } from '../../cpp/types/libhongtu/Index';
import { parsePhysicalLayerStack } from '../models/PhysicalLayerStack';
import type { PhysicalLayerStack, PhysicalStackParseResult } from '../models/PhysicalLayerStack';
import { cloneStructured } from './CloneUtils';

export interface TechnologyLayer {
  name: string;
  layerNumber: number;
  datatype: number;
  purpose: string;
  color: string;
}
export interface TechnologyDevice {
  name: string;
  pcell: string;
  model: string;
  parameters: Record<string, number | string | boolean>;
}
export interface TechnologyPackage {
  schema: string;
  id: string;
  name: string;
  version: string;
  source: string;
  license: string;
  qualification: string;
  layers: TechnologyLayer[];
  viaLayers: NativeViaLayer[];
  drcRules: DrcRule[];
  devices: TechnologyDevice[];
  drcDeckId: string;
  lvsDeckId: string;
  layerStack?: PhysicalLayerStack;
}
export interface TechnologyParseResult {
  ok: boolean;
  error: string;
  technology?: TechnologyPackage;
}

function requireText(value: string, field: string, max: number = 512): void {
  if (typeof value !== 'string' || value.length === 0 || value.length > max || value.includes('\0')) throw new Error(`${field} 必须为 1–${max} 字符且不含 NUL`);
}
function requireLayer(value: number, field: string): void {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 32767) throw new Error(`${field} 必须为 0–32767 整数`);
}
function pair(layer: number, datatype: number): string { return `${layer}/${datatype}`; }

/** Pure all-or-nothing validation. An imported package never executes scripts or remaps geometry. */
export function parseTechnologyPackage(text: string): TechnologyParseResult {
  try {
    if (text.length > 2 * 1024 * 1024) throw new Error('工艺包超过 2 MiB 文本上限');
    const tech: TechnologyPackage = JSON.parse(text) as TechnologyPackage;
    if (tech === null || tech.schema !== 'hongtu-technology/v1') throw new Error('schema 必须为 hongtu-technology/v1');
    requireText(tech.id, 'id', 80);
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(tech.id)) throw new Error('id 仅允许字母、数字、点、横线和下划线');
    requireText(tech.name, 'name', 120); requireText(tech.version, 'version', 80);
    requireText(tech.source, 'source', 2000); requireText(tech.license, 'license', 1000);
    if (['unverified', 'public-subset', 'user-validated'].indexOf(tech.qualification) < 0) throw new Error('qualification 应为 unverified/public-subset/user-validated；导入不构成签核');
    if (!Array.isArray(tech.layers) || tech.layers.length === 0 || tech.layers.length > 4096) throw new Error('layers 需要 1–4096 个图层映射');
    const pairs: string[] = [];
    for (const layer of tech.layers) {
      requireText(layer.name, 'layer.name', 120); requireLayer(layer.layerNumber, 'layerNumber'); requireLayer(layer.datatype, 'datatype');
      requireText(layer.purpose, 'purpose', 80);
      if (typeof layer.color !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(layer.color)) throw new Error('图层 color 应为 #RRGGBB');
      const key: string = pair(layer.layerNumber, layer.datatype);
      if (pairs.indexOf(key) >= 0) throw new Error(`重复图层映射 ${key}`);
      pairs.push(key);
    }
    if (!Array.isArray(tech.viaLayers) || tech.viaLayers.length > 1024) throw new Error('viaLayers 必须是最多 1024 项的数组');
    const viaKeys: string[] = [];
    for (const via of tech.viaLayers) {
      requireLayer(via.viaLayer, 'viaLayer'); requireLayer(via.lowerLayer, 'lowerLayer'); requireLayer(via.upperLayer, 'upperLayer');
      requireLayer(via.viaDatatype ?? -1, 'viaDatatype'); requireLayer(via.lowerDatatype ?? -1, 'lowerDatatype'); requireLayer(via.upperDatatype ?? -1, 'upperDatatype');
      if (via.viaLayer === via.lowerLayer || via.viaLayer === via.upperLayer || via.lowerLayer === via.upperLayer) throw new Error('通孔、上下导体必须为不同层号');
      const vk: string = pair(via.viaLayer, via.viaDatatype ?? -1);
      if (pairs.indexOf(vk) < 0 || pairs.indexOf(pair(via.lowerLayer, via.lowerDatatype ?? -1)) < 0 || pairs.indexOf(pair(via.upperLayer, via.upperDatatype ?? -1)) < 0) throw new Error(`通孔 ${vk} 引用了未声明的图层用途`);
      const key: string = `${vk}:${via.lowerLayer}/${via.lowerDatatype}:${via.upperLayer}/${via.upperDatatype}`;
      if (viaKeys.indexOf(key) >= 0) throw new Error('重复通孔连通项');
      viaKeys.push(key);
    }
    if (!Array.isArray(tech.drcRules) || tech.drcRules.length > 4096) throw new Error('drcRules 必须为最多 4096 项数组');
    if (tech.drcRules.length > 0) {
      const checked = parseRuleSetText(JSON.stringify({ name: tech.name, rules: tech.drcRules }));
      if (!checked.ok) throw new Error(`DRC 规则：${checked.error}`);
      tech.drcRules = checked.rules;
    }
    if (!Array.isArray(tech.devices) || tech.devices.length > 512) throw new Error('devices 必须为最多 512 项数组');
    const devices: string[] = [];
    for (const device of tech.devices) {
      requireText(device.name, 'device.name', 120); requireText(device.pcell, 'device.pcell', 120); requireText(device.model, 'device.model', 120);
      if (devices.indexOf(device.name) >= 0) throw new Error(`重复器件名 ${device.name}`);
      devices.push(device.name);
      if (device.parameters === null || typeof device.parameters !== 'object' || Array.isArray(device.parameters)) throw new Error('器件 parameters 必须是参数对象');
      const keys: string[] = Object.keys(device.parameters);
      if (keys.length > 128) throw new Error('器件参数超过 128 项');
      for (const key of keys) {
        requireText(key, 'device.parameters.key', 120);
        if (['__proto__', 'prototype', 'constructor'].indexOf(key) >= 0 || key.includes('\0')) throw new Error('器件参数名称无效');
        const value: number | string | boolean = device.parameters[key];
        if (typeof value === 'number' && !Number.isFinite(value)) throw new Error('器件数值必须有限');
        if (typeof value !== 'number' && typeof value !== 'string' && typeof value !== 'boolean') throw new Error('器件参数仅允许数字、文本或布尔值');
        if (typeof value === 'string' && (value.length > 65536 || value.includes('\0'))) throw new Error('器件文本参数无效或超过 65536 字符');
      }
    }
    for (const id of [tech.drcDeckId, tech.lvsDeckId]) {
      if (typeof id !== 'string' || id.length > 120 || (id.length > 0 && !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(id))) throw new Error('验证 deck 仅允许已注册的 ID，不能填代码或路径');
    }
    if (tech.layerStack !== undefined) {
      const checked: PhysicalStackParseResult = parsePhysicalLayerStack(JSON.stringify(tech.layerStack), tech.layers);
      if (!checked.ok || checked.stack === undefined) throw new Error(`物理层栈：${checked.message}`);
      tech.layerStack = checked.stack;
    }
    return { ok: true, error: '', technology: tech };
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}

export function technologyTemplate(): TechnologyPackage {
  return { schema: 'hongtu-technology/v1', id: 'my-process', name: '自定义工艺', version: '1.0',
    source: '请填写规则来源', license: '请填写授权范围', qualification: 'unverified',
    layers: [
      { name: 'M1', layerNumber: 1, datatype: 0, purpose: 'drawing', color: '#327CE8' },
      { name: 'V1', layerNumber: 10, datatype: 0, purpose: 'cut', color: '#E89A32' },
      { name: 'M2', layerNumber: 2, datatype: 0, purpose: 'drawing', color: '#E873A2' }
    ], viaLayers: [{ viaLayer: 10, viaDatatype: 0, lowerLayer: 1, lowerDatatype: 0, upperLayer: 2, upperDatatype: 0 }],
    drcRules: [], devices: [], drcDeckId: '', lvsDeckId: '' };
}

export function sky130SubsetTechnology(): TechnologyPackage {
  return { schema: 'hongtu-technology/v1', id: 'sky130', name: 'SKY130 met1 公开子集', version: 'm1.1-m1.2-m1.6',
    source: 'https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html#m1',
    license: '规则来源为公开 SKY130 文档；目标工艺授权与完整规则另行配置', qualification: 'public-subset',
    layers: [{ name: 'met1', layerNumber: 68, datatype: 20, purpose: 'drawing', color: '#327CE8' }],
    viaLayers: [], drcRules: cloneStructured(RULESET_SKY130_MET1.rules) as DrcRule[], devices: [],
    drcDeckId: 'sky130-met1-public', lvsDeckId: '' };
}

export function klayoutDemoTechnology(): TechnologyPackage {
  const names: string[] = ['nwell', 'active', 'pplus', 'nplus', 'poly', 'contact', 'metal1', 'via1', 'metal2'];
  const colors: string[] = ['#AED5F5', '#73BC83', '#E8AFA4', '#B7C98B', '#E46D66', '#6C7078', '#327CE8', '#D99444', '#E873A2'];
  const layers: TechnologyLayer[] = [];
  for (let i: number = 0; i < names.length; i++) layers.push({ name: names[i], layerNumber: i + 1, datatype: 0,
    purpose: i === 5 || i === 7 ? 'cut' : 'drawing', color: colors[i] });
  layers.push({ name: 'metal1_labels', layerNumber: 7, datatype: 1, purpose: 'label', color: '#327CE8' });
  layers.push({ name: 'metal2_labels', layerNumber: 9, datatype: 1, purpose: 'label', color: '#E873A2' });
  return { schema: 'hongtu-technology/v1', id: 'klayout-demo', name: 'KLayout MOS4 演示工艺', version: 'demo-1',
    source: 'https://www.klayout.de/doc-qt5/manual/lvs_intro.html',
    license: 'KLayout 官方教学示例；仅供该演示工艺验证', qualification: 'public-subset', layers: layers,
    viaLayers: [{ viaLayer: 8, viaDatatype: 0, lowerLayer: 7, lowerDatatype: 0, upperLayer: 9, upperDatatype: 0 }],
    drcRules: [], devices: [], drcDeckId: '', lvsDeckId: 'klayout-demo-mos4' };
}
