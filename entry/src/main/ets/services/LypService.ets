/**
 * KLayout .lyp 图层属性文件互通（gap-matrix §5）
 *
 * 解析标准 KLayout `<layer-properties><properties>` XML（.lyp），
 * 导出标准 KLayout XML，同时兼容读取历史鸿图 `<klayout-layer-properties>` 格式。
 * 设计约束：
 * - 解析 / 序列化均为纯字符串函数，不依赖 picker / UI，可在 aboutToAppear 自检中调用
 *   （与 constants.canvasTransformConsistent() 同一先例）。
 * - 手写 XML 扫描（HarmonyOS NEXT 无内置 XML DOM），对真实文件噪声保持容忍：
 *   UTF-8 BOM、CRLF、注释、CDATA、属性形式 <layer .../>、未知元素（跳过并记警告，绝不崩溃）。
 * - 模型无法表达的特性不伪造：记入 warnings 向上暴露（见 lypFeatureGaps()）。
 *
 * .lyp <layer> 文本节点形式：
 *   "layer"|"datatype"  properties  brightness  contrast  saturation  hue
 *   linewidth  linetype  areastyle  fillcolor  framecolor
 *   + <transparent>、<name>、<source>
 *
 * 映射到鸿图 UiLayer（common/types.ets）：
 *   frame/fill 颜色 → color；frame/fill 开关 → visible；<transparent> → transparency；
 *   linewidth → lineWidth；linetype → lineStyle；areastyle → fillStyle；
 *   <select>>0 → selectable；<bold> → highlighted；<animation> → animated（仅记录）。
 *   丢弃（警告）：brightness/contrast/saturation/hue 非中性、<vas>、组嵌套、复合线型/填充参数。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { UiLayer, LayerGroup } from '../common/types';
import { cloneLayerWithVisible } from '../workbench/WorkbenchData';
import { safeFilePublishService } from './SafeFilePublishService';
import type { SourceLayerDefinition } from '../../cpp/types/libhongtu/Index';

/** 一条 .lyp <layer> 条目（解析产物 / 序列化输入，纯数据） */
export interface LypLayerEntry {
  sourceName?: string;
  declaredEmpty?: boolean;
  /** 层号（无法解析时 -1，条目被丢弃并警告） */
  layerNumber: number;
  /** datatype */
  datatype: number;
  /** KLayout 显示名（<name>），空串 = 无 */
  displayName: string;
  /** 组名（嵌套组拍平为最内层名），空串 = 根层 */
  groupName: string;
  /** '#RRGGBB'，空串 = none / 未指定 */
  frameColor: string;
  /** '#RRGGBB'，空串 = none / 未指定 */
  fillColor: string;
  /** 0-100 */
  transparency: number;
  /** 像素，0 = 自动/未指定 */
  lineWidth: number;
  /** solid/dashed/dotted/dotdash，空串 = 未指定 */
  lineStyle: string;
  /** solid/outline/cross/diagonal/hollow，空串 = 未指定 */
  fillStyle: string;
  /** frame 或 fill 任一开启 */
  visible: boolean;
  /** <bold> */
  bold: boolean;
  /** <vas>（鸿图无渲染对应，往返导出可还原） */
  vas: boolean;
  /** <select> 0-3 */
  selectMode: number;
  /** <animation> mode!=none（鸿图尚无闪烁渲染，仅记录开关） */
  animated: boolean;
}

/** parseLyp 结果 */
export interface LypParseResult {
  layerDefinitions?: SourceLayerDefinition[];
  layers: LypLayerEntry[];
  warnings: string[];
}

/** mergeLypIntoLayers 结果 */
export interface LypMergeResult {
  layers: UiLayer[];
  appliedCount: number;
  warnings: string[];
}

/** picker 读回的文本文件 */
export interface LypFileContent {
  uri: string;
  fileName: string;
  text: string;
}

/** 组名映射结果 */
export interface LypGroupMapping {
  group: LayerGroup;
  mapped: boolean;
}

/** 无法表达特性的固定清单（导入反馈与交接文档共用） */
export function lypFeatureGaps(): string[] {
  return [
    'brightness/contrast/saturation/hue（HSV 调色）无对应，非中性时丢弃并警告',
    '<vas>（区域阴影）无渲染对应：条目内保留以往返导出，鸿图画布忽略',
    '<animation> 仅记录 animated 开关，画布尚无闪烁渲染（gap-matrix §5 动画层）',
    'layer-group 嵌套层级拍平为最内层组名；组名不属于鸿图 4 个固定分组时归入「其他」并警告',
    'linetype/areastyle 复合格式串（"a:b:c"）近似为最近线型/填充型，图案参数丢弃',
    'GDS 库前缀层源（"LIB""1"/0）忽略库名，仅取层号/datatype',
    '<layer-text> 紧凑文本格式（KLayout 手写粘贴形式）不支持，按未知元素跳过并警告',
  ];
}

// ============ 小工具（纯函数，避开正则与宿主差异） ============

function isDigits(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (c < '0' || c > '9') {
      return false;
    }
  }
  return true;
}

function isHexColorBody(hex: string): boolean {
  for (let i = 0; i < hex.length; i++) {
    const c: string = hex.charAt(i);
    const ok: boolean = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
    if (!ok) {
      return false;
    }
  }
  return true;
}

function clampNum(v: number, lo: number, hi: number): number {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

function splitWs(raw: string): string[] {
  const out: string[] = [];
  const parts: string[] = raw.split(' ');
  for (let i = 0; i < parts.length; i++) {
    const p: string = parts[i].trim();
    if (p.length > 0) {
      out.push(p);
    }
  }
  return out;
}

function unquote(t: string): string {
  if (t.length >= 2 && t.charAt(0) === '"' && t.charAt(t.length - 1) === '"') {
    return t.substring(1, t.length - 1);
  }
  return t;
}

function isQuoted(t: string): boolean {
  return t.length >= 2 && t.charAt(0) === '"' && t.charAt(t.length - 1) === '"';
}

/** KLayout 基础色名 → '#RRGGBB'，未知名返回 '' */
function namedColor(t: string): string {
  if (t === 'black') {
    return '#000000';
  }
  if (t === 'white') {
    return '#ffffff';
  }
  if (t === 'red') {
    return '#ff0000';
  }
  if (t === 'green') {
    return '#00ff00';
  }
  if (t === 'blue') {
    return '#0000ff';
  }
  if (t === 'cyan') {
    return '#00ffff';
  }
  if (t === 'magenta') {
    return '#ff00ff';
  }
  if (t === 'yellow') {
    return '#ffff00';
  }
  if (t === 'gray' || t === 'grey') {
    return '#808080';
  }
  if (t === 'orange') {
    return '#ff8000';
  }
  return '';
}

/** 颜色 token → '#RRGGBB'；显式 none → ''；非颜色 → null */
function parseColorToken(tok: string): string | null {
  const t: string = unquote(tok).toLowerCase();
  if (t === 'none' || t === '-' || t === 'transparent') {
    return '';
  }
  if (t.charAt(0) === '#') {
    const hex: string = t.substring(1);
    if (hex.length === 6 && isHexColorBody(hex)) {
      return '#' + hex;
    }
    if (hex.length === 3 && isHexColorBody(hex)) {
      return '#' + hex.charAt(0) + hex.charAt(0) + hex.charAt(1) + hex.charAt(1) +
        hex.charAt(2) + hex.charAt(2);
    }
    return null;
  }
  const named: string = namedColor(t);
  return named.length > 0 ? named : null;
}

/** '"1"/0' / '1/0' / '1.44' / '"GDS""1"/0' → [layer, datatype]；失败 [-1, 0] */
function parseLayerSpec(tok: string): number[] {
  let s: string = '';
  for (let i = 0; i < tok.length; i++) {
    const c: string = tok.charAt(i);
    if (c !== '"') {
      s += c;
    }
  }
  // KLayout source 的 @ 后缀是 cellview 索引，不属于 datatype。
  const at: number = s.lastIndexOf('@');
  if (at >= 0) {
    const cv: string = s.substring(at + 1);
    if (cv !== '*' && !isDigits(cv)) return [-1, 0];
    s = s.substring(0, at);
  }
  let layerPart: string = s;
  let dtPart: string = '0';
  const slash: number = s.lastIndexOf('/');
  const dot: number = s.lastIndexOf('.');
  const sep: number = slash >= 0 ? slash : dot;
  if (sep > 0 && sep < s.length - 1) {
    const maybeDt: string = s.substring(sep + 1);
    if (isDigits(maybeDt)) {
      layerPart = s.substring(0, sep);
      dtPart = maybeDt;
    }
  }
  if (!isDigits(layerPart)) {
    return [-1, 0];
  }
  const layer: number = parseInt(layerPart, 10);
  const datatype: number = parseInt(dtPart, 10);
  if (layer > 32767 || datatype > 32767) return [-1, 0];
  return [layer, datatype];
}

function specToSource(layerNumber: number, datatype: number): string {
  return '"' + layerNumber.toString() + '/' + datatype.toString() + '"';
}

/** linetype 串 → 鸿图 lineStyle；无法精确表达时近似 + 警告 */
function mapLinetype(raw: string, warn: (m: string) => void): string {
  if (raw.length === 0) {
    return '';
  }
  if (raw === '0') {
    return 'solid';
  }
  if (raw === '1') {
    return 'dashed';
  }
  if (raw === '2') {
    return 'dotted';
  }
  if (raw === '3') {
    return 'dotdash';
  }
  if (raw.indexOf(':') >= 0) {
    warn('linetype "' + raw + '" 为自定义虚线参数串，近似为 dashed，参数丢弃');
    return 'dashed';
  }
  if (isDigits(raw)) {
    warn('linetype "' + raw + '" 超出 0-3，近似为 dotdash');
    return 'dotdash';
  }
  warn('linetype "' + raw + '" 无法识别，忽略');
  return '';
}

/** areastyle 串 → 鸿图 fillStyle；无法精确表达时近似 + 警告 */
function mapAreastyle(raw: string, warn: (m: string) => void): string {
  const t: string = raw.toLowerCase();
  if (t.length === 0) {
    return '';
  }
  if (t === '0') {
    return 'hollow';
  }
  if (t === '1' || t === 'i') {
    return 'solid';
  }
  if (t === '2' || t === 'x') {
    return 'cross';
  }
  if (t === '3' || t === 'v' || t === 'h') {
    return 'diagonal';
  }
  if (t.indexOf(':') >= 0) {
    warn('areastyle "' + raw + '" 为复杂填充图案，近似为 diagonal，参数丢弃');
    return 'diagonal';
  }
  warn('areastyle "' + raw + '" 无法识别，忽略');
  return '';
}

function linetypeFromStyle(style: string): string {
  if (style === 'dashed') {
    return '1';
  }
  if (style === 'dotted') {
    return '2';
  }
  if (style === 'dotdash') {
    return '3';
  }
  if (style === 'solid') {
    return '0';
  }
  return '';
}

function areastyleFromFill(style: string): string {
  if (style === 'solid') {
    return 'I';
  }
  if (style === 'cross') {
    return 'X';
  }
  if (style === 'diagonal') {
    return 'V';
  }
  if (style === 'hollow') {
    return '0';
  }
  if (style === 'outline') {
    return '0';
  }
  return '';
}

// ============ XML 预处理 ============

/** 去 BOM、CRLF→LF、展开 CDATA（保留内容）、剥注释与声明 */
function sanitizeLypXml(xml: string): string {
  let s: string = xml;
  if (s.length > 0 && s.charCodeAt(0) === 0xFEFF) {
    s = s.substring(1);
  }
  let lf: string = '';
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (c === '\r') {
      lf += '\n';
    } else {
      lf += c;
    }
  }
  s = lf;
  let cdataOut: string = '';
  let i2: number = 0;
  while (i2 < s.length) {
    const idx: number = s.indexOf('<![CDATA[', i2);
    if (idx < 0) {
      cdataOut += s.substring(i2);
      break;
    }
    cdataOut += s.substring(i2, idx);
    const end: number = s.indexOf(']]>', idx + 9);
    if (end < 0) {
      cdataOut += escapeXml(s.substring(idx + 9));
      break;
    }
    cdataOut += escapeXml(s.substring(idx + 9, end));
    i2 = end + 3;
  }
  s = cdataOut;
  let noComment: string = '';
  let i3: number = 0;
  while (i3 < s.length) {
    const idx: number = s.indexOf('<!--', i3);
    if (idx < 0) {
      noComment += s.substring(i3);
      break;
    }
    noComment += s.substring(i3, idx);
    const end: number = s.indexOf('-->', idx + 4);
    i3 = end < 0 ? s.length : end + 3;
  }
  s = noComment;
  let noDecl: string = '';
  let i4: number = 0;
  while (i4 < s.length) {
    const idx: number = s.indexOf('<!', i4);
    if (idx < 0) {
      noDecl += s.substring(i4);
      break;
    }
    noDecl += s.substring(i4, idx);
    const end: number = s.indexOf('>', idx);
    i4 = end < 0 ? s.length : end + 1;
  }
  return noDecl;
}

/** 属性扫描（尊重引号内的空白与 '>'） */
function parseTagAttrs(body: string): Map<string, string> {
  const attrs: Map<string, string> = new Map<string, string>();
  let i: number = 0;
  while (i < body.length) {
    while (i < body.length && (body.charAt(i) === ' ' || body.charAt(i) === '\t' ||
      body.charAt(i) === '\n')) {
      i++;
    }
    let name: string = '';
    while (i < body.length && body.charAt(i) !== '=' && body.charAt(i) !== ' ' &&
      body.charAt(i) !== '\t' && body.charAt(i) !== '\n' && body.charAt(i) !== '/' &&
      body.charAt(i) !== '>') {
      name += body.charAt(i);
      i++;
    }
    if (name.length === 0) {
      break;
    }
    if (i >= body.length || body.charAt(i) !== '=') {
      continue;
    }
    i++;
    if (i >= body.length || (body.charAt(i) !== '"' && body.charAt(i) !== '\'')) {
      continue;
    }
    const quote: string = body.charAt(i);
    i++;
    let value: string = '';
    while (i < body.length && body.charAt(i) !== quote) {
      value += body.charAt(i);
      i++;
    }
    i++;
    attrs.set(name, unescapeXml(value));
  }
  return attrs;
}

function unescapeXml(s: string): string {
  if (s.indexOf('&') < 0) {
    return s;
  }
  let out: string = '';
  let i: number = 0;
  while (i < s.length) {
    if (s.charAt(i) === '&') {
      const semi: number = s.indexOf(';', i);
      if (semi > i && semi - i <= 6) {
        const ent: string = s.substring(i + 1, semi);
        if (ent === 'amp') {
          out += '&';
          i = semi + 1;
          continue;
        }
        if (ent === 'lt') {
          out += '<';
          i = semi + 1;
          continue;
        }
        if (ent === 'gt') {
          out += '>';
          i = semi + 1;
          continue;
        }
        if (ent === 'quot') {
          out += '"';
          i = semi + 1;
          continue;
        }
        if (ent === 'apos') {
          out += '\'';
          i = semi + 1;
          continue;
        }
      }
    }
    out += s.charAt(i);
    i++;
  }
  return out;
}

function escapeXml(s: string): string {
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (c === '&') {
      out += '&amp;';
    } else if (c === '<') {
      out += '&lt;';
    } else if (c === '>') {
      out += '&gt;';
    } else if (c === '"') {
      out += '&quot;';
    } else {
      out += c;
    }
  }
  return out;
}

/** 标签闭 '>'（属性值可含 '>'，尊重引号） */
function findTagEnd(s: string, lt: number): number {
  let quote: string = '';
  for (let i = lt + 1; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (quote.length === 0 && (c === '"' || c === '\'')) {
      quote = c;
    } else if (quote.length > 0 && c === quote) {
      quote = '';
    } else if (c === '>' && quote.length === 0) {
      return i;
    }
  }
  return s.length;
}

function firstWs(body: string): number {
  for (let i = 0; i < body.length; i++) {
    const c: string = body.charAt(i);
    if (c === ' ' || c === '\t' || c === '\n') {
      return i;
    }
  }
  return -1;
}

function isLayerLeaf(name: string): boolean {
  return name === 'frame' || name === 'fill' || name === 'select' || name === 'vas' ||
    name === 'bold' || name === 'transparent' || name === 'name' || name === 'source';
}

function isKnownLypElement(name: string): boolean {
  if (isLayerLeaf(name)) {
    return true;
  }
  return name === 'klayout-layer-properties' || name === 'layer-group' || name === 'name' ||
    name === 'description' || name === 'layer' || name === 'animation' || name === 'period' ||
    name === 'color' || name === 'configuration' || name === 'layer-text' || name === 'group';
}

// ============ frame/fill 元组 ============

function newEntry(): LypLayerEntry {
  const e: LypLayerEntry = {
    layerNumber: -1, datatype: 0, displayName: '', groupName: '', frameColor: '', fillColor: '',
    transparency: 0, lineWidth: 0, lineStyle: '', fillStyle: '', visible: false, bold: false,
    vas: false, selectMode: 0, animated: false,
  };
  return e;
}

/**
 * frame/fill 文本 → 条目。位置式字段，缺尾不报错；颜色按 token 识别：
 * frame 节点色 → frameColor；fill 节点第 1 色 → fillColor、第 2 色 → framecolor。
 * 属性形式（frame="1"）由 parseLayerAttrs 处理，不走这里。
 */
function applyTupleText(raw: string, isFill: boolean, e: LypLayerEntry, warn: (m: string) => void): void {
  const tokens: string[] = splitWs(raw);
  if (tokens.length === 0) {
    return;
  }
  let i: number = 0;
  const first: string = tokens[0];
  const onlyProp: boolean = tokens.length === 1 && (first === '0' || first === '1');
  if (!onlyProp) {
    const spec: number[] = parseLayerSpec(first);
    if (spec[0] >= 0) {
      e.layerNumber = spec[0];
      e.datatype = spec[1];
      i = 1;
    }
  }
  // properties 开关：'1' 开启可见；'0' 不否定另一节点的开启（visible = frame||fill）
  if (i < tokens.length && !isQuoted(tokens[i]) && (tokens[i] === '0' || tokens[i] === '1')) {
    if (tokens[i] === '1') {
      e.visible = true;
    }
    i++;
  }
  // HSV 4 值（数字，128 中性）
  let hsv: number = 0;
  while (i < tokens.length && hsv < 4 && !isQuoted(tokens[i]) &&
    (isDigits(tokens[i]) || (tokens[i].length > 1 && tokens[i].charAt(0) === '-' && isDigits(tokens[i].substring(1))))) {
    const v: number = parseInt(tokens[i], 10);
    if (v !== 128) {
      if (hsv === 3) {
        warn('hue 调色 (' + v.toString() + ') 无对应显示能力，已丢弃');
      } else {
        warn('亮度/对比度/饱和度调色 (' + v.toString() + ') 无对应显示能力，已丢弃');
      }
    }
    i++;
    hsv++;
  }
  // linewidth（数字）
  if (i < tokens.length && !isQuoted(tokens[i]) && isDigits(tokens[i])) {
    const lw: number = parseInt(tokens[i], 10);
    if (lw > 0) {
      e.lineWidth = lw;
    }
    i++;
  }
  // 尾部槽位：linetype, areastyle, fillcolor, framecolor（或颜色穿插）
  // 槽位游标必须是本节点的局部状态：e.lineStyle 可能已由 frame 节点先行写入
  let colorSeen: number = 0;
  let sawLt: boolean = false;
  let sawAs: boolean = false;
  while (i < tokens.length) {
    const t: string = tokens[i];
    const color: string | null = parseColorToken(t);
    if (color !== null) {
      if (isFill) {
        if (colorSeen === 0) {
          e.fillColor = color;
        } else {
          e.frameColor = color;
        }
      } else {
        e.frameColor = color;
      }
      colorSeen++;
      i++;
      continue;
    }
    if (!sawLt) {
      const ls: string = mapLinetype(unquote(t), warn);
      if (ls.length > 0) {
        e.lineStyle = ls;
      }
      sawLt = true;
      i++;
      continue;
    }
    if (!sawAs) {
      const fs2: string = mapAreastyle(unquote(t), warn);
      if (fs2.length > 0) {
        e.fillStyle = fs2;
      }
      sawAs = true;
      i++;
      continue;
    }
    // 剩余未识别 token：容忍跳过
    i++;
  }
}

/** 属性形式 <layer source=".." frame=".." fill=".." transparent=".." name=".."/> */
function parseLayerAttrs(attrs: Map<string, string>, e: LypLayerEntry, warn: (m: string) => void): void {
  const source: string | undefined = attrs.get('source');
  if (source !== undefined) {
    const spec: number[] = parseLayerSpec(source);
    if (spec[0] >= 0) {
      e.layerNumber = spec[0];
      e.datatype = spec[1];
    } else {
      warn('<layer source="' + source + '"> 无法解析层号');
    }
  }
  const frame: string | undefined = attrs.get('frame');
  if (frame !== undefined) {
    if (frame === '1') {
      e.visible = true;
    } else if (frame === '0') {
      e.visible = false;
    } else {
      applyTupleText(frame, false, e, warn);
    }
  }
  const fill: string | undefined = attrs.get('fill');
  if (fill !== undefined) {
    if (fill === '1' && e.layerNumber >= 0) {
      // fill 开启（颜色另议）
      const hasColor: boolean = parseColorToken(fill) !== null;
      if (!hasColor) {
        e.visible = true;
      }
    } else if (fill !== '0') {
      applyTupleText(fill, true, e, warn);
    }
  }
  const transparent: string | undefined = attrs.get('transparent');
  if (transparent !== undefined) {
    applyTransparent(transparent, e);
  }
  const name: string | undefined = attrs.get('name');
  if (name !== undefined) {
    e.displayName = name;
  }
}

/** <transparent>：'0' | '1 [0-100]'（缺省值按 KLayout 惯例 50） */
function applyTransparent(raw: string, e: LypLayerEntry): void {
  const tokens: string[] = splitWs(raw);
  if (tokens.length === 0) {
    return;
  }
  if (tokens[0] === '0') {
    e.transparency = 0;
    return;
  }
  if (tokens.length >= 2 && isDigits(tokens[1])) {
    e.transparency = clampNum(parseInt(tokens[1], 10), 0, 100);
  } else {
    e.transparency = 50;
  }
}

/** 组名 → 鸿图 LayerGroup（闭枚举仅 4 值） */
export function mapGroupName(name: string): LypGroupMapping {
  if (name === LayerGroup.INTERCONNECT) {
    return { group: LayerGroup.INTERCONNECT, mapped: true };
  }
  if (name === LayerGroup.DOPING) {
    return { group: LayerGroup.DOPING, mapped: true };
  }
  if (name === LayerGroup.CONTACT) {
    return { group: LayerGroup.CONTACT, mapped: true };
  }
  if (name === LayerGroup.OTHER || name.length === 0) {
    return { group: LayerGroup.OTHER, mapped: true };
  }
  return { group: LayerGroup.OTHER, mapped: false };
}

// ============ 解析（单遍事件流） ============

interface StandardLypNode {
  entry: LypLayerEntry;
  children: StandardLypNode[];
  source: string;
  depth: number;
}

/** 读取标准 KLayout LYP 的叶字段；不支持的显示效果明确给出警告。 */
function applyStandardLeaf(node: StandardLypNode, name: string, text: string, warn: (m: string) => void): void {
  const e: LypLayerEntry = node.entry;
  if (name === 'name') e.displayName = text;
  else if (name === 'source') node.source = text;
  else if (name === 'visible') e.visible = e.visible && text !== 'false' && text !== '0';
  else if (name === 'valid') e.visible = e.visible && text !== 'false' && text !== '0';
  else if (name === 'frame-color' || name === 'fill-color') {
    const color: string | null = parseColorToken(text);
    if (color === null) warn('标准 LYP 无法解析颜色 ' + text);
    else if (name === 'frame-color') e.frameColor = color;
    else e.fillColor = color;
  } else if (name === 'transparent') e.transparency = text === 'true' || text === '1' ? 50 : 0;
  else if (name === 'marked') e.bold = text === 'true' || text === '1';
  else if (name === 'width') {
    const width: number = Number(text);
    if (Number.isFinite(width) && width >= 0 && width <= 100) e.lineWidth = width;
    else warn('标准 LYP width 超出显示范围，已忽略');
  } else if (name === 'animation') {
    e.animated = text !== '0' && text !== 'none';
    if (e.animated) warn('标准 LYP animation 仅记录开关，闪烁渲染未实现');
  } else if (name === 'dither-pattern') {
    if (text === 'I0') e.fillStyle = 'solid';
    else if (text === 'I1') e.fillStyle = 'outline';
    else if (text.length > 0) warn('标准 LYP dither-pattern ' + text + ' 无精确显示映射，保留图层并使用默认填充');
  } else if (name === 'line-style') {
    if (text === 'I0') e.lineStyle = 'solid';
    else if (text.length > 0) warn('标准 LYP line-style ' + text + ' 无精确显示映射，保留图层并使用默认线型');
  } else if (name === 'frame-brightness' || name === 'fill-brightness') {
    if (text !== '0') warn('标准 LYP brightness 无显示映射，已忽略');
  } else if (name === 'xfill') {
    if (text === 'true' || text === '1') warn('标准 LYP xfill 无精确显示映射，已忽略');
  } else if (name !== 'expanded') {
    warn('标准 LYP 未知显示字段 <' + name + '> 已忽略，图层 source 保留');
  }
}

function finishStandardNode(node: StandardLypNode, parent: LypLayerEntry | null,
  result: LypParseResult, warn: (m: string) => void): void {
  const e: LypLayerEntry = node.entry;
  if (parent !== null) {
    e.visible = e.visible && parent.visible;
    if (e.frameColor.length === 0) e.frameColor = parent.frameColor;
    if (e.fillColor.length === 0) e.fillColor = parent.fillColor;
    e.groupName = parent.displayName;
  }
  if (node.children.length > 0) {
    warn('标准 LYP 图层组已拍平，保留最内层组名及继承的可见性');
    for (const child of node.children) finishStandardNode(child, e, result, warn);
    return;
  }
  const spec: number[] = parseLayerSpec(node.source);
  if (spec[0] < 0) {
    warn('标准 LYP source "' + node.source + '" 不是可应用的数值二元组，未改动文档中其他图层');
    return;
  }
  const at: number = node.source.lastIndexOf('@');
  if (at >= 0 && node.source.substring(at + 1) !== '1' && node.source.substring(at + 1) !== '*') {
    warn('标准 LYP cellview 索引被映射到当前文档；layer/datatype 保持原值');
  }
  e.layerNumber = spec[0];
  e.datatype = spec[1];
  result.layers.push(e);
}

function parseStandardLyp(s: string): LypParseResult {
  const result: LypParseResult = { layers: [], warnings: [] };
  const warn = (message: string): void => {
    if (result.warnings.length < 60 && result.warnings.indexOf(message) < 0) result.warnings.push(message);
  };
  const roots: StandardLypNode[] = [];
  const nodes: StandardLypNode[] = [];
  const stack: string[] = [];
  let cursor: number = 0;
  let nodeCount: number = 0;
  while (cursor < s.length) {
    const lt: number = s.indexOf('<', cursor);
    const text: string = unescapeXml(s.substring(cursor, lt < 0 ? s.length : lt).trim());
    const node: StandardLypNode | undefined = nodes.length > 0 ? nodes[nodes.length - 1] : undefined;
    if (node !== undefined && text.length > 0 && stack.length === node.depth + 1) {
      applyStandardLeaf(node, stack[stack.length - 1], text, warn);
    }
    if (lt < 0) break;
    const gt: number = findTagEnd(s, lt);
    const raw: string = s.substring(lt + 1, gt).trim();
    cursor = gt + 1;
    if (raw.length === 0 || raw.charAt(0) === '?') continue;
    if (raw.charAt(0) === '/') {
      const name: string = raw.substring(1).trim();
      if (stack.length === 0 || stack[stack.length - 1] !== name) {
        warn('标准 LYP 标签未正确闭合，已停止读取后续条目');
        break;
      }
      if (node !== undefined && node.depth === stack.length) nodes.pop();
      stack.pop();
      continue;
    }
    const selfClose: boolean = raw.endsWith('/');
    const body: string = selfClose ? raw.substring(0, raw.length - 1).trim() : raw;
    const space: number = firstWs(body);
    const name: string = space < 0 ? body : body.substring(0, space);
    const parent: string = stack.length > 0 ? stack[stack.length - 1] : '';
    const isNode: boolean = (name === 'properties' && parent === 'layer-properties') ||
      (name === 'group-members' && node !== undefined && stack.length === node.depth);
    if (isNode) {
      if (++nodeCount > 10000 || nodes.length >= 64) {
        warn('标准 LYP 超出 10000 条目或 64 层组嵌套限制，已停止读取');
        break;
      }
      const entry: LypLayerEntry = newEntry();
      entry.visible = true;
      entry.selectMode = 1;
      const created: StandardLypNode = { entry: entry, children: [], source: '', depth: stack.length + 1 };
      if (node === undefined) roots.push(created);
      else node.children.push(created);
      if (!selfClose) nodes.push(created);
    }
    if (!selfClose) stack.push(name);
  }
  if (stack.length > 0) warn('标准 LYP 文件未完整闭合，请检查文件完整性');
  for (const root of roots) finishStandardNode(root, null, result, warn);
  return result;
}

/**
 * 解析 .lyp XML。绝不抛异常：无法识别的内容降级为警告，未闭合标签按到达边界处理。
 */
interface LypSourceIdentity { layerNumber: number; datatype: number; sourceName: string; declaredEmpty: boolean; }
interface LypSourceMetadata { version: number; layers: LypSourceIdentity[]; layerDefinitions: SourceLayerDefinition[]; }

export function parseLyp(xml: string): LypParseResult {
  const result: LypParseResult = parseLypCore(xml);
  const marker: RegExpMatchArray | null = xml.match(/<!-- hongtu-source-layers-v1:([0-9a-f]+) -->/);
  if (marker === null) return result;
  try {
    const encoded: string = marker[1];
    if (encoded.length > 16 * 1024 * 1024 || encoded.length % 4 !== 0) throw new Error('元数据长度无效');
    let decoded: string = '';
    for (let i: number = 0; i < encoded.length; i += 4) decoded += String.fromCharCode(parseInt(encoded.substring(i, i + 4), 16));
    const metadata: LypSourceMetadata = JSON.parse(decoded) as LypSourceMetadata;
    if (metadata.version !== 1 || !Array.isArray(metadata.layers) || metadata.layers.length > 10000 ||
      !Array.isArray(metadata.layerDefinitions) || metadata.layerDefinitions.length > 100000) throw new Error('元数据结构无效');
    for (const identity of metadata.layers) {
      if (!Number.isInteger(identity.layerNumber) || identity.layerNumber < 0 || identity.layerNumber > 32767 ||
        !Number.isInteger(identity.datatype) || identity.datatype < 0 || identity.datatype > 32767 ||
        typeof identity.sourceName !== 'string' || identity.sourceName.length > 65535 || identity.sourceName.includes('\0') ||
        typeof identity.declaredEmpty !== 'boolean') throw new Error('源层身份无效');
    }
    for (const definition of metadata.layerDefinitions) {
      if (definition === null || typeof definition.name !== 'string' || definition.name.length > 65535 ||
        definition.name.includes('\0') || typeof definition.textLayer !== 'boolean') throw new Error('源层定义无效');
      for (const interval of [definition.layer, definition.datatype]) {
        if (interval === null || interval === undefined || !Number.isInteger(interval.type) || interval.type < 0 || interval.type > 4 ||
          !Number.isInteger(interval.lower) || !Number.isInteger(interval.upper) || interval.lower < 0 || interval.upper > 4294967295 ||
          interval.lower > interval.upper || (interval.type === 0 && (interval.lower !== 0 || interval.upper !== 4294967295)) ||
          (interval.type === 1 && interval.lower !== 0) || (interval.type === 2 && interval.upper !== 4294967295) ||
          (interval.type === 3 && interval.lower !== interval.upper)) throw new Error('源层定义区间无效');
      }
    }
    for (const identity of metadata.layers) {
      const entry: LypLayerEntry | undefined = result.layers.find((item: LypLayerEntry) => item.layerNumber === identity.layerNumber && item.datatype === identity.datatype);
      if (entry !== undefined) { entry.sourceName = identity.sourceName; entry.declaredEmpty = identity.declaredEmpty; }
    }
    result.layerDefinitions = metadata.layerDefinitions;
  } catch (error) { result.warnings.push(`鸿图源图层元数据未应用：${String(error)}`); }
  return result;
}

function parseLypCore(xml: string): LypParseResult {
  const normalized: string = sanitizeLypXml(xml);
  if (/<layer-properties(?:\s|>)/.test(normalized)) return parseStandardLyp(normalized);
  const result: LypParseResult = { layers: [], warnings: [] };
  const seen: string[] = [];
  const addWarn = (m: string): void => {
    for (let i = 0; i < seen.length; i++) {
      if (seen[i] === m) {
        return;
      }
    }
    if (result.warnings.length < 60 && seen.length < 60) {
      seen.push(m);
      result.warnings.push(m);
    }
  };
  const s: string = normalized;
  const stack: string[] = []; // 打开元素栈（含文本归属的叶子）
  const groupStack: string[] = []; // 打开的 layer-group 名（索引与栈中 layer-group 深度对应）
  const groupStackMarks: number[] = []; // 每个打开 layer-group 在 stack 中的深度
  let cur: LypLayerEntry | null = null;

  let i: number = 0;
  while (i < s.length) {
    const lt: number = s.indexOf('<', i);
    const textEnd: number = lt < 0 ? s.length : lt;
    const text: string = s.substring(i, textEnd).trim();
    if (text.length > 0 && stack.length > 0) {
      const top: string = stack[stack.length - 1];
      const parent: string = stack.length >= 2 ? stack[stack.length - 2] : '';
      if (top === 'name' && parent === 'layer-group' && groupStack.length > 0) {
        groupStack[groupStack.length - 1] = text;
      } else if (top === 'description' || top === 'period' || top === 'color') {
        // 已知但鸿图无对应，静默忽略
      } else if (cur !== null && top === 'name' && parent === 'layer') {
        cur.displayName = unescapeXml(text);
      } else if (cur !== null && isLayerLeaf(top)) {
        applyLeafTextTo(cur, top, text, addWarn);
      }
    }
    if (lt < 0) {
      break;
    }
    const gt: number = findTagEnd(s, lt);
    const rawTag: string = s.substring(lt + 1, gt);
    i = gt + 1;
    if (rawTag.length === 0) {
      continue;
    }
    if (rawTag.charAt(0) === '?') {
      continue;
    }
    if (rawTag.charAt(0) === '/') {
      const name: string = unquote(rawTag.substring(1).trim());
      closeElement(name, stack, groupStack, groupStackMarks, cur, result, addWarn);
      if (name === 'layer') {
        cur = null;
      }
      continue;
    }
    const selfClose: boolean = rawTag.charAt(rawTag.length - 1) === '/';
    const body: string = selfClose ? rawTag.substring(0, rawTag.length - 1) : rawTag;
    const sp: number = firstWs(body);
    const name: string = sp < 0 ? body : body.substring(0, sp);
    const attrText: string = sp < 0 ? '' : body.substring(sp + 1);

    if (name === 'layer') {
      const attrs: Map<string, string> = parseTagAttrs(attrText);
      const e: LypLayerEntry = newEntry();
      e.groupName = currentGroupName(groupStack, addWarn);
      if (attrText.length > 0) {
        parseLayerAttrs(attrs, e, addWarn);
      }
      if (selfClose) {
        finishLayer(e, result, addWarn);
      } else {
        cur = e;
        stack.push(name);
      }
      continue;
    }
    if (name === 'layer-group' || name === 'group') {
      if (name === 'group') {
        addWarn('未知元素 <group> 按 layer-group 近似处理');
      }
      if (!selfClose) {
        groupStack.push('');
        groupStackMarks.push(stack.length);
        stack.push('layer-group');
      }
      continue;
    }
    if (!isKnownLypElement(name)) {
      addWarn('未知元素 <' + name + '> 已跳过');
    }
    if (cur !== null && name === 'animation') {
      const attrs2: Map<string, string> = parseTagAttrs(attrText);
      const mode: string | undefined = attrs2.get('mode');
      cur.animated = mode === undefined || mode !== 'none';
      if (cur.animated) {
        addWarn('检测到 <animation>：仅记录 animated 开关，闪烁渲染未实现');
      }
    }
    // KLayout 元素属性形式：<fill transparent="1 50">（与 <transparent> 子元素二选一，均支持）
    if (cur !== null && (name === 'frame' || name === 'fill') && attrText.length > 0) {
      const attrs3: Map<string, string> = parseTagAttrs(attrText);
      const tr: string | undefined = attrs3.get('transparent');
      if (tr !== undefined) {
        applyTransparent(tr, cur);
      }
    }
    if (selfClose) {
      continue;
    }
    stack.push(name);
  }
  // 未闭合的 <layer> 在 EOF 也要结算（容忍截断文件）
  if (cur !== null) {
    finishLayer(cur, result, addWarn);
  }
  return result;
}

function currentGroupName(groupStack: string[], warn: (m: string) => void): string {
  if (groupStack.length === 0) {
    return '';
  }
  const name: string = groupStack[groupStack.length - 1];
  if (groupStack.length > 1) {
    warn('layer-group 嵌套已拍平（保留最内层组名 "' + name + '"）');
  }
  return name;
}

function closeElement(
  name: string,
  stack: string[],
  groupStack: string[],
  groupStackMarks: number[],
  cur: LypLayerEntry | null,
  result: LypParseResult,
  warn: (m: string) => void
): void {
  // 弹到该名字（容忍交错闭合）
  let found: number = -1;
  for (let i = stack.length - 1; i >= 0; i--) {
    if (stack[i] === name) {
      found = i;
      break;
    }
  }
  if (found >= 0) {
    // ArkTS 禁改 Array.length，逐个 pop 到目标深度
    while (stack.length > found) {
      stack.pop();
    }
  }
  if (name === 'layer-group') {
    if (groupStackMarks.length > 0) {
      groupStackMarks.pop();
      groupStack.pop();
    }
  }
  if (name === 'layer' && cur !== null) {
    finishLayer(cur, result, warn);
  }
}

function finishLayer(e: LypLayerEntry, result: LypParseResult, warn: (m: string) => void): void {
  if (e.layerNumber < 0) {
    warn('无法解析层号的 <layer> 条目已跳过' + (e.displayName.length > 0 ? '（' + e.displayName + '）' : ''));
    return;
  }
  result.layers.push(e);
}

function applyLeafTextTo(e: LypLayerEntry, leaf: string, text: string, warn: (m: string) => void): void {
  if (leaf === 'frame') {
    applyTupleText(text, false, e, warn);
    return;
  }
  if (leaf === 'fill') {
    applyTupleText(text, true, e, warn);
    return;
  }
  if (leaf === 'transparent') {
    applyTransparent(text, e);
    return;
  }
  if (leaf === 'source') {
    const spec: number[] = parseLayerSpec(text);
    if (spec[0] >= 0) {
      e.layerNumber = spec[0];
      e.datatype = spec[1];
    } else {
      warn('<source> "' + text + '" 无法解析层号（GDS 库前缀已忽略）');
    }
    return;
  }
  if (leaf === 'select') {
    const t: string[] = splitWs(text);
    if (t.length > 0 && isDigits(t[0])) {
      e.selectMode = clampNum(parseInt(t[0], 10), 0, 3);
    }
    return;
  }
  if (leaf === 'vas') {
    e.vas = text === '1';
    return;
  }
  if (leaf === 'bold') {
    e.bold = text === '1';
    return;
  }
}

// ============ 序列化 ============

/**
 * 写出标准 KLayout .lyp；不支持的显示细节见 lypExportWarnings。
 * 名称、完整二元组、颜色、可见性、宽度保持；百分比透明度只导出布尔开关。
 */
export function formatLyp(entries: LypLayerEntry[], layerDefinitions: SourceLayerDefinition[] = []): string {
  const sorted: LypLayerEntry[] = entries.slice();
  sorted.sort((a: LypLayerEntry, b: LypLayerEntry): number => {
    if (a.groupName !== b.groupName) {
      return a.groupName < b.groupName ? -1 : 1;
    }
    if (a.layerNumber !== b.layerNumber) {
      return a.layerNumber - b.layerNumber;
    }
    return a.datatype - b.datatype;
  });
  let out: string = '<?xml version="1.0" encoding="utf-8"?>\n<layer-properties>\n';
  // Standard readers ignore this XML comment; HongTu restores source identity separately.
  // Hex-encoded UTF-16 cannot introduce '--', markup, or invalid XML comment syntax.
  if (layerDefinitions.length > 0 || entries.some((entry: LypLayerEntry) => entry.sourceName !== undefined || entry.declaredEmpty === true)) {
    const metadata: LypSourceMetadata = { version: 1,
      layers: entries.map((entry: LypLayerEntry): LypSourceIdentity => ({ layerNumber: entry.layerNumber,
        datatype: entry.datatype, sourceName: entry.sourceName ?? '', declaredEmpty: entry.declaredEmpty === true })), layerDefinitions };
    const json: string = JSON.stringify(metadata);
    let encoded: string = '';
    for (let i: number = 0; i < json.length; i++) encoded += json.charCodeAt(i).toString(16).padStart(4, '0');
    out += ' <!-- hongtu-source-layers-v1:' + encoded + ' -->\n';
  }
  const warnings: string[] = lypExportWarnings(entries);
  for (const warning of warnings) out += ' <!-- HongTu: ' + escapeXml(warning) + ' -->\n';
  let i: number = 0;
  while (i < sorted.length) {
    const g: string = sorted[i].groupName;
    if (g.length === 0) {
      out += formatStandardLayer(sorted[i], 'properties', ' ');
      i++;
      continue;
    }
    let j: number = i;
    while (j < sorted.length && sorted[j].groupName === g) {
      j++;
    }
    out += ' <properties>\n  <name>' + escapeXml(g) + '</name>\n  <source>*/*@*</source>\n  <visible>true</visible>\n';
    for (let k = i; k < j; k++) {
      out += formatStandardLayer(sorted[k], 'group-members', '  ');
    }
    out += ' </properties>\n';
    i = j;
  }
  out += '</layer-properties>\n';
  return out;
}

export function lypExportWarnings(entries: LypLayerEntry[]): string[] {
  const warnings: string[] = [];
  if (entries.some(e => e.transparency > 0 && e.transparency !== 50)) {
    warnings.push('百分比透明度转为 KLayout transparent 布尔开关，百分比不能精确保留');
  }
  if (entries.some(e => e.lineStyle.length > 0 && e.lineStyle !== 'solid')) {
    warnings.push('自定义线型导出为默认实线');
  }
  if (entries.some(e => e.fillStyle.length > 0 && e.fillStyle !== 'solid' && e.fillStyle !== 'outline' && e.fillStyle !== 'hollow')) {
    warnings.push('自定义填充图案导出为实心填充');
  }
  if (entries.some(e => e.selectMode !== 1 || e.vas || e.animated)) {
    warnings.push('可选锁定、VAS 和动画设置无完整标准映射，导出时忽略');
  }
  return warnings;
}

function formatStandardLayer(e: LypLayerEntry, tag: string, indent: string): string {
  if (!Number.isInteger(e.layerNumber) || !Number.isInteger(e.datatype) ||
    e.layerNumber < 0 || e.layerNumber > 32767 || e.datatype < 0 || e.datatype > 32767) {
    throw new Error('LYP layer/datatype 必须是 0..32767 的整数');
  }
  const hollow: boolean = e.fillColor.length === 0 || e.fillStyle === 'outline' || e.fillStyle === 'hollow';
  const child: string = indent + ' ';
  let out: string = indent + '<' + tag + '>\n';
  out += child + '<name>' + escapeXml(e.displayName) + '</name>\n';
  out += child + '<source>' + e.layerNumber.toString() + '/' + e.datatype.toString() + '@1</source>\n';
  out += child + '<frame-color>' + escapeXml(e.frameColor) + '</frame-color>\n';
  out += child + '<fill-color>' + escapeXml(e.fillColor) + '</fill-color>\n';
  out += child + '<visible>' + (e.visible ? 'true' : 'false') + '</visible>\n';
  out += child + '<valid>true</valid>\n';
  out += child + '<transparent>' + (e.transparency > 0 ? 'true' : 'false') + '</transparent>\n';
  out += child + '<width>' + (Number.isFinite(e.lineWidth) && e.lineWidth > 0 ? e.lineWidth.toString() : '') + '</width>\n';
  out += child + '<marked>' + (e.bold ? 'true' : 'false') + '</marked>\n';
  out += child + '<dither-pattern>' + (hollow ? 'I1' : 'I0') + '</dither-pattern>\n';
  out += child + '<line-style>I0</line-style>\n';
  out += child + '<animation>0</animation>\n';
  out += indent + '</' + tag + '>\n';
  return out;
}

// ============ UiLayer ↔ LypLayerEntry ============

/** 由当前文档图层构造导出条目（应用侧单一真源：Index.ets @State layers） */
export function entriesFromUiLayers(layers: UiLayer[]): LypLayerEntry[] {
  const out: LypLayerEntry[] = [];
  for (let i = 0; i < layers.length; i++) {
    const l: UiLayer = layers[i];
    const e: LypLayerEntry = newEntry();
    e.layerNumber = l.layerNumber;
    e.datatype = l.datatype;
    e.displayName = l.chineseName;
    e.sourceName = l.sourceName;
    e.declaredEmpty = l.elementCount === 0;
    e.groupName = l.group; // LayerGroup 闭枚举的中文值即组名
    e.frameColor = l.color;
    e.fillColor = l.fillColor !== undefined && l.fillColor.length > 0 ? l.fillColor : l.color;
    e.visible = l.visible;
    e.transparency = l.transparency !== undefined ? clampNum(l.transparency, 0, 100) : 0;
    e.lineWidth = l.lineWidth !== undefined ? Math.max(0, Math.round(l.lineWidth)) : 0;
    e.lineStyle = l.lineStyle !== undefined ? l.lineStyle : '';
    e.fillStyle = l.fillStyle !== undefined ? l.fillStyle : '';
    e.selectMode = l.selectable !== false ? 1 : 0;
    e.bold = l.highlighted === true;
    e.animated = l.animated === true;
    out.push(e);
  }
  return out;
}

/**
 * 合并 .lyp 条目：仅更新 (layerNumber, datatype) 精确命中的层，其余原样返回。
 * 与 applyLayerPresetToLayers 同一状态路径：返回全新 UiLayer[]，由调用方赋回 @State
 * 并 syncLayerVisibilityMirror()，画布与视图镜像自然生效。
 */
export function mergeLypIntoLayers(layers: UiLayer[], entries: LypLayerEntry[]): LypMergeResult {
  const warnings: string[] = [];
  const matched: boolean[] = [];
  for (let j = 0; j < entries.length; j++) {
    matched.push(false);
  }
  const next: UiLayer[] = [];
  let applied: number = 0;
  for (let i = 0; i < layers.length; i++) {
    const layer: UiLayer = layers[i];
    let hit: number = -1;
    for (let j = 0; j < entries.length; j++) {
      if (entries[j].layerNumber === layer.layerNumber && entries[j].datatype === layer.datatype) {
        hit = j;
        break;
      }
    }
    if (hit < 0) {
      next.push(layer);
      continue;
    }
    matched[hit] = true;
    const e: LypLayerEntry = entries[hit];
    const updated: UiLayer = cloneLayerWithVisible(layer, e.visible);
    if (e.sourceName !== undefined) updated.sourceName = e.sourceName;
    if (e.frameColor.length > 0) {
      updated.color = e.frameColor;
    } else if (e.fillColor.length > 0) {
      updated.color = e.fillColor;
    }
    if (e.fillColor.length > 0) {
      updated.fillColor = e.fillColor;
    } else if (e.frameColor.length > 0) {
      updated.fillColor = undefined;
    }
    updated.transparency = e.transparency;
    if (e.lineWidth > 0) {
      updated.lineWidth = e.lineWidth;
    }
    if (e.lineStyle.length > 0) {
      updated.lineStyle = e.lineStyle;
    }
    if (e.fillStyle.length > 0) {
      updated.fillStyle = e.fillStyle;
    }
    if (e.displayName.length > 0) {
      updated.chineseName = e.displayName;
    }
    updated.selectable = e.selectMode > 0;
    updated.highlighted = e.bold;
    updated.animated = e.animated;
    const gm: LypGroupMapping = mapGroupName(e.groupName);
    updated.group = gm.group;
    applied++;
    next.push(updated);
  }
  for (let j = 0; j < entries.length; j++) {
    if (!matched[j]) {
      const e: LypLayerEntry = entries[j];
      if (e.declaredEmpty === true || e.sourceName !== undefined) {
        next.push({ layerNumber: e.layerNumber, datatype: e.datatype,
          chineseName: e.displayName || e.sourceName || `图层${e.layerNumber}`, englishName: `L${e.layerNumber}`,
          sourceName: e.sourceName, color: e.frameColor || e.fillColor || '#808080',
          fillColor: e.fillColor.length > 0 ? e.fillColor : undefined, visible: e.visible,
          elementCount: 0, group: mapGroupName(e.groupName).group, lineWidth: e.lineWidth,
          lineStyle: e.lineStyle, fillStyle: e.fillStyle, transparency: e.transparency, selectable: e.selectMode > 0 });
        applied++;
        continue;
      }
      warnings.push('L' + entries[j].layerNumber.toString() + '/' + entries[j].datatype.toString() +
        ' 在当前文档无对应图层，未应用');
    }
  }
  return { layers: next, appliedCount: applied, warnings: warnings };
}

// ============ picker / 文件 IO（纯解析不依赖此段） ============

export class LypService {
  /** 文档选择器读取 .lyp（复用 FileImportService 的 picker 模式） */
  async pickAndReadLyp(context: common.UIAbilityContext): Promise<LypFileContent> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.select({
      fileSuffixFilters: ['图层属性文件|.lyp'],
      maxSelectNumber: 1,
    });
    if (uris.length === 0) {
      throw new Error('未选择文件');
    }
    return await this.readLypFromUri(uris[0]);
  }

  /** 从指定 URI（含 UDMF 拖拽落入）读取 .lyp 文本与显示文件名 */
  async readLypFromUri(uri: string): Promise<LypFileContent> {
    const text: string = await this.readTextFromUri(uri);
    return { uri: uri, fileName: this.nameFromUri(uri), text: text };
  }

  /** 保存选择器写出 .lyp 文本，返回目标 uri */
  async pickAndWriteLyp(context: common.UIAbilityContext, fileName: string, xml: string): Promise<string> {
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.save({
      newFileNames: [fileName],
      fileSuffixChoices: ['图层属性文件|.lyp'],
    });
    if (uris.length === 0) {
      throw new Error('未选择保存位置');
    }
    const uri: string = uris[0];
    const data: Uint8Array = new util.TextEncoder().encodeInto(xml);
    safeFilePublishService.publishBuffer(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength), uri, context.cacheDir);
    return uri;
  }

  /** uri → UTF-8 文本（BOM 由解析层剥离） */
  async readTextFromUri(uri: string): Promise<string> {
    const file: fs.File = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat: fs.Stat = fs.statSync(file.fd);
      const size: number = Number(stat.size);
      if (!Number.isSafeInteger(size) || size <= 0 || size > 8 * 1024 * 1024) throw new Error('LYP 文件应为非空且不超过 8 MiB');
      const bytes: Uint8Array = new Uint8Array(size);
      let offset: number = 0;
      while (offset < size) {
        const buffer: ArrayBuffer = new ArrayBuffer(Math.min(64 * 1024, size - offset));
        const read: number = await fs.read(file.fd, buffer, { length: buffer.byteLength });
        if (!Number.isSafeInteger(read) || read <= 0 || read > buffer.byteLength) throw new Error('LYP 文件读取不完整，当前图层配置已保留');
        bytes.set(new Uint8Array(buffer, 0, read), offset);
        offset += read;
      }
      if (Number(fs.statSync(file.fd).size) !== size) throw new Error('LYP 文件在读取期间发生变化，请重新导入');
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(bytes);
    } finally {
      fs.closeSync(file);
    }
  }

  private nameFromUri(uri: string): string {
    const pathPart: string = uri.split(/[?#]/)[0];
    const slash: number = pathPart.lastIndexOf('/');
    const raw: string = slash >= 0 ? pathPart.substring(slash + 1) : pathPart;
    try {
      return decodeURIComponent(raw);
    } catch (_error) {
      return raw;
    }
  }
}

export const lypService: LypService = new LypService();

// ============ 自检（与 constants.canvasTransformConsistent 同先例） ============

function entrySig(e: LypLayerEntry): string {
  return e.layerNumber.toString() + '|' + e.datatype.toString() + '|' + e.displayName + '|' +
    e.groupName + '|' + e.frameColor + '|' + e.fillColor + '|' + e.transparency.toString() + '|' +
    e.lineWidth.toString() + '|' + e.lineStyle + '|' + e.fillStyle + '|' +
    (e.visible ? '1' : '0') + '|' + (e.bold ? '1' : '0') + '|' + (e.vas ? '1' : '0') + '|' +
    e.selectMode.toString() + '|' + (e.animated ? '1' : '0');
}

/** 噪声样例：BOM + CRLF + 注释 + CDATA + 属性形式层 + 嵌套组 + 未知 animation */
const LYP_SELFTEST_SAMPLE: string =
  '\uFEFF<?xml version="1.0" encoding="UTF-8"?>\r\n' +
  '<!-- KLayout layer properties -->\r\n' +
  '<klayout-layer-properties>\r\n' +
  '  <layer-group>\r\n' +
  '    <description>演示</description>\r\n' +
  '    <name>互连层</name>\r\n' +
  '    <layer>\r\n' +
  '      <frame>"1/0" 1 128 128 128 128 2 "1"</frame>\r\n' +
  '      <fill transparent="1 50">"1/0" 1 128 128 128 128 0 "" "" #ff0000 #c80000</fill>\r\n' +
  '      <select>2</select>\r\n' +
  '      <vas>0</vas>\r\n' +
  '      <bold>0</bold>\r\n' +
  '      <name><![CDATA[有源区]]></name>\r\n' +
  '      <source>"1/0"</source>\r\n' +
  '    </layer>\r\n' +
  '    <layer-group>\r\n      <name>M1</name>\r\n' +
  '      <layer><frame>"2/0" 1</frame><fill>"2/0" 1 128 128 128 128 0 "" "" #00ff00 #00ff00</fill><name>金属一</name></layer>\r\n' +
  '    </layer-group>\r\n' +
  '    <layer source="44/0" frame="1" fill="0"/>\r\n' +
  '  </layer-group>\r\n' +
  '</klayout-layer-properties>\r\n';

function findLayer(layers: LypLayerEntry[], ln: number, dt: number): LypLayerEntry | undefined {
  for (let i = 0; i < layers.length; i++) {
    if (layers[i].layerNumber === ln && layers[i].datatype === dt) {
      return layers[i];
    }
  }
  return undefined;
}

function hasColor(e: LypLayerEntry, c: string): boolean {
  return e.frameColor === c || e.fillColor === c;
}

/**
 * .lyp 自检：旧格式导入 + 标准格式导出的可表示字段往返。
 * 不可精确表示的样式和百分比透明度必须由 lypExportWarnings 报告。
 * 仅供 aboutToAppear console.warn（本工程 ArkTS 侧无测试框架）。
 */
export function lypSelfCheck(): string {
  const parsed: LypParseResult = parseLyp(LYP_SELFTEST_SAMPLE);
  if (parsed.layers.length !== 3) {
    return '期望解析出 3 层，实际 ' + parsed.layers.length.toString();
  }
  const l0: LypLayerEntry | undefined = findLayer(parsed.layers, 1, 0);
  if (l0 === undefined || l0.frameColor !== '#c80000' || l0.fillColor !== '#ff0000' ||
    l0.transparency !== 50 || l0.displayName !== '有源区' || l0.groupName !== '互连层' ||
    l0.lineStyle !== 'dashed' || l0.lineWidth !== 2 || l0.selectMode !== 2 || !l0.visible) {
    return '第 1 层字段不符：' + (l0 !== undefined ? entrySig(l0) : '缺失');
  }
  const l1: LypLayerEntry | undefined = findLayer(parsed.layers, 2, 0);
  if (l1 === undefined || !hasColor(l1, '#00ff00') || l1.groupName !== 'M1' || l1.animated !== false ||
    l1.displayName !== '金属一') {
    return '第 2 层字段不符：' + (l1 !== undefined ? entrySig(l1) : '缺失');
  }
  const l2: LypLayerEntry | undefined = findLayer(parsed.layers, 44, 0);
  if (l2 === undefined || l2.visible !== true || l2.fillColor !== '') {
    return '属性形式层解析失败：' + (l2 !== undefined ? entrySig(l2) : '缺失');
  }
  if (parsed.warnings.length === 0) {
    return '应至少产生组名拍平/未知元素警告';
  }
  const again: LypParseResult = parseLyp(formatLyp(parsed.layers));
  if (again.layers.length !== parsed.layers.length) {
    return '往返层数不一致：' + again.layers.length.toString();
  }
  for (let i = 0; i < parsed.layers.length; i++) {
    const a: LypLayerEntry | undefined = findLayer(again.layers, parsed.layers[i].layerNumber,
      parsed.layers[i].datatype);
    const original: LypLayerEntry = parsed.layers[i];
    if (a === undefined || a.layerNumber !== original.layerNumber || a.datatype !== original.datatype ||
      a.displayName !== original.displayName || a.frameColor !== original.frameColor ||
      a.fillColor !== original.fillColor || a.visible !== original.visible || a.groupName !== original.groupName) {
      return '往返不一致：' + entrySig(parsed.layers[i]) + ' vs ' +
        (a !== undefined ? entrySig(a) : '缺失');
    }
  }
  const ui: UiLayer = {
    layerNumber: 7, datatype: 3, chineseName: '多晶硅', englishName: 'POLY', color: '#12ab34',
    visible: true, elementCount: 0, group: LayerGroup.OTHER,
    transparency: 40, lineWidth: 3, lineStyle: 'dotted', fillStyle: 'cross',
  };
  const uiAgain: LypParseResult = parseLyp(formatLyp(entriesFromUiLayers([ui])));
  const u0: LypLayerEntry | undefined = findLayer(uiAgain.layers, 7, 3);
  if (u0 === undefined || u0.frameColor !== '#12ab34' || u0.transparency !== 50 || u0.lineWidth !== 3 ||
    u0.lineStyle !== 'solid' || u0.fillStyle !== 'solid' || !u0.visible || u0.displayName !== '多晶硅' ||
    lypExportWarnings(entriesFromUiLayers([ui])).length < 3) {
    return 'UiLayer 往返不一致：' + (u0 !== undefined ? entrySig(u0) : '缺失');
  }
  const merged: LypMergeResult = mergeLypIntoLayers([ui], uiAgain.layers);
  if (merged.appliedCount !== 1 || merged.layers[0].color !== '#12ab34' ||
    merged.layers[0].transparency !== 50) {
    return 'mergeLypIntoLayers 行为不符';
  }
  const missed: LypMergeResult = mergeLypIntoLayers([ui], parsed.layers);
  if (missed.warnings.length < 3) {
    return '未命中条目应全部产生警告（期望>=3，实际 ' + missed.warnings.length.toString() + '）';
  }
  return '';
}
