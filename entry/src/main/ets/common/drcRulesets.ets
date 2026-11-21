/**
 * 鸿图 DRC 规则集预设定义
 *
 * 定义 DRC 规则类型、严重等级枚举与 28nm / 14nm / 7nm 三种工艺节点的
 * 默认规则集。DrcService 从此文件导入类型与规则集，并重新导出类型以
 * 保持对外 API 向后兼容。
 *
 * 本文件只负责「类型 + 内置预设 + 读文件文本」；规则清单的**解析**在
 * `drcRuleText.ets`（纯函数，可在 host 跑断言），此处不再重复一套解析逻辑。
 *
 * 规则集数值参考主流工艺节点典型值：
 * - 28nm：与 DrcService.createDefaultRules 保持一致
 * - 14nm：按约 0.7x 缩放
 * - 7nm：进一步收紧
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { fileIo as fs } from '@kit.CoreFileKit';

/** DRC 规则严重等级 */
export enum DrcSeverity {
  ERROR = 'error',
  WARNING = 'warning',
  INFO = 'info',
}

/** DRC 规则类型 */
export enum DrcRuleType {
  MIN_WIDTH = 'min_width',
  MIN_SPACING = 'min_spacing',
  MIN_AREA = 'min_area',
  MIN_ENCLOSURE = 'min_enclosure',
  DENSITY = 'density',
}

/**
 * DRC 规则定义
 *
 * `datatype` / `targetDatatype` are optional: omitted means any purpose;
 * an explicit number, including zero, is matched exactly by both engines.
 * 由用户规则清单（`common/drcRuleText.ets::parseRuleSetText`）解析得到。
 */
export interface DrcRule {
  /** 规则唯一标识（如 'MW_M1'），用于 setEnabled / setValue 定位 */
  id: string;
  /** 规则中文名 */
  name: string;
  /** 规则类型 */
  type: DrcRuleType;
  /** 所在图层编号 */
  layerNumber: number;
  /**
   * 目标图层编号（仅 MIN_ENCLOSURE 规则使用）。
   * 表示包围层（如 Poly 应被 AA 包围时，targetLayerNumber=AA 的层号）。
   * -1 表示未指定，checkMinEnclosure 将检查设计中所有其他图层。
   */
  targetLayerNumber: number;
  /** 规则参数值（nm / nm²） */
  value: number;
  /** 严重等级 */
  severity: DrcSeverity;
  /** 规则描述 */
  description: string;
  /** 是否启用 */
  enabled: boolean;
  /** 图层 datatype：未给 = 任意，显式 0 精确匹配 */
  datatype?: number;
  /** 包围层 datatype：仅 MIN_ENCLOSURE 使用，未给 = 任意 */
  targetDatatype?: number;
}

/** DRC 规则集定义 */
export interface DrcRuleset {
  /** 规则集名称（如 '28nm默认'） */
  name: string;
  /** 工艺节点：'28nm' / '14nm' / '7nm' */
  process: string;
  /** 规则列表 */
  rules: DrcRule[];
}

/** 28nm 默认规则集（10 条规则，作为 createDefaultRules 的单一数据源） */
export const RULESET_28NM: DrcRuleset = {
  name: '28nm默认',
  process: '28nm',
  rules: [
    { id: 'MW_M1', name: '金属1最小宽度', type: DrcRuleType.MIN_WIDTH, targetLayerNumber: -1,layerNumber: 1, value: 90, severity: DrcSeverity.ERROR, description: 'M1 线宽不小于 90nm', enabled: true },
    { id: 'MW_M2', name: '金属2最小宽度', type: DrcRuleType.MIN_WIDTH, targetLayerNumber: -1,layerNumber: 2, value: 100, severity: DrcSeverity.ERROR, description: 'M2 线宽不小于 100nm', enabled: true },
    { id: 'MW_Poly', name: '多晶硅最小宽度', type: DrcRuleType.MIN_WIDTH, targetLayerNumber: -1,layerNumber: 4, value: 50, severity: DrcSeverity.ERROR, description: 'Poly 线宽不小于 50nm', enabled: true },
    { id: 'MS_M1', name: '金属1最小间距', type: DrcRuleType.MIN_SPACING, targetLayerNumber: -1,layerNumber: 1, value: 90, severity: DrcSeverity.ERROR, description: 'M1 间距不小于 90nm', enabled: true },
    { id: 'MS_M2', name: '金属2最小间距', type: DrcRuleType.MIN_SPACING, targetLayerNumber: -1,layerNumber: 2, value: 100, severity: DrcSeverity.ERROR, description: 'M2 间距不小于 100nm', enabled: true },
    { id: 'MS_Poly', name: '多晶硅最小间距', type: DrcRuleType.MIN_SPACING, targetLayerNumber: -1,layerNumber: 4, value: 60, severity: DrcSeverity.ERROR, description: 'Poly 间距不小于 60nm', enabled: true },
    { id: 'MA_M1', name: '金属1最小面积', type: DrcRuleType.MIN_AREA, targetLayerNumber: -1, layerNumber: 1, value: 8100, severity: DrcSeverity.WARNING, description: 'M1 面积不小于 8100nm² (90x90)', enabled: true },
    { id: 'MA_AA', name: '有源区最小面积', type: DrcRuleType.MIN_AREA, targetLayerNumber: -1, layerNumber: 5, value: 2500, severity: DrcSeverity.WARNING, description: 'AA 面积不小于 2500nm² (50x50)', enabled: true },
    { id: 'ME_Poly_AA', name: '多晶硅超出有源区包围', type: DrcRuleType.MIN_ENCLOSURE, layerNumber: 4, targetLayerNumber: 5, value: 20, severity: DrcSeverity.WARNING, description: 'Poly 应超出 AA 边缘至少 20nm', enabled: true },
    { id: 'DEN_M1', name: '金属1最小密度', type: DrcRuleType.DENSITY, targetLayerNumber: -1, layerNumber: 1, value: 20, severity: DrcSeverity.WARNING, description: 'M1 窗口覆盖率不低于 20%', enabled: true },
  ],
};

/** 14nm 默认规则集（参数更严格，约 0.7x 缩放） */
export const RULESET_14NM: DrcRuleset = {
  name: '14nm默认',
  process: '14nm',
  rules: [
    { id: 'MW_M1', name: '金属1最小宽度', type: DrcRuleType.MIN_WIDTH, targetLayerNumber: -1,layerNumber: 1, value: 64, severity: DrcSeverity.ERROR, description: 'M1 线宽不小于 64nm', enabled: true },
    { id: 'MW_M2', name: '金属2最小宽度', type: DrcRuleType.MIN_WIDTH, targetLayerNumber: -1,layerNumber: 2, value: 70, severity: DrcSeverity.ERROR, description: 'M2 线宽不小于 70nm', enabled: true },
    { id: 'MW_Poly', name: '多晶硅最小宽度', type: DrcRuleType.MIN_WIDTH, targetLayerNumber: -1,layerNumber: 4, value: 35, severity: DrcSeverity.ERROR, description: 'Poly 线宽不小于 35nm', enabled: true },
    { id: 'MS_M1', name: '金属1最小间距', type: DrcRuleType.MIN_SPACING, targetLayerNumber: -1,layerNumber: 1, value: 64, severity: DrcSeverity.ERROR, description: 'M1 间距不小于 64nm', enabled: true },
    { id: 'MS_M2', name: '金属2最小间距', type: DrcRuleType.MIN_SPACING, targetLayerNumber: -1,layerNumber: 2, value: 70, severity: DrcSeverity.ERROR, description: 'M2 间距不小于 70nm', enabled: true },
    { id: 'MS_Poly', name: '多晶硅最小间距', type: DrcRuleType.MIN_SPACING, targetLayerNumber: -1,layerNumber: 4, value: 42, severity: DrcSeverity.ERROR, description: 'Poly 间距不小于 42nm', enabled: true },
    { id: 'MA_M1', name: '金属1最小面积', type: DrcRuleType.MIN_AREA, targetLayerNumber: -1, layerNumber: 1, value: 4096, severity: DrcSeverity.WARNING, description: 'M1 面积不小于 4096nm² (64x64)', enabled: true },
    { id: 'MA_AA', name: '有源区最小面积', type: DrcRuleType.MIN_AREA, targetLayerNumber: -1, layerNumber: 5, value: 1225, severity: DrcSeverity.WARNING, description: 'AA 面积不小于 1225nm² (35x35)', enabled: true },
    { id: 'ME_Poly_AA', name: '多晶硅超出有源区包围', type: DrcRuleType.MIN_ENCLOSURE, layerNumber: 4, targetLayerNumber: 5, value: 14, severity: DrcSeverity.WARNING, description: 'Poly 应超出 AA 边缘至少 14nm', enabled: true },
    { id: 'DEN_M1', name: '金属1最小密度', type: DrcRuleType.DENSITY, targetLayerNumber: -1, layerNumber: 1, value: 18, severity: DrcSeverity.WARNING, description: 'M1 窗口覆盖率不低于 18%', enabled: true },
  ],
};

/** 7nm 默认规则集（参数最严格） */
export const RULESET_7NM: DrcRuleset = {
  name: '7nm默认',
  process: '7nm',
  rules: [
    { id: 'MW_M1', name: '金属1最小宽度', type: DrcRuleType.MIN_WIDTH, targetLayerNumber: -1,layerNumber: 1, value: 36, severity: DrcSeverity.ERROR, description: 'M1 线宽不小于 36nm', enabled: true },
    { id: 'MW_M2', name: '金属2最小宽度', type: DrcRuleType.MIN_WIDTH, targetLayerNumber: -1,layerNumber: 2, value: 40, severity: DrcSeverity.ERROR, description: 'M2 线宽不小于 40nm', enabled: true },
    { id: 'MW_Poly', name: '多晶硅最小宽度', type: DrcRuleType.MIN_WIDTH, targetLayerNumber: -1,layerNumber: 4, value: 24, severity: DrcSeverity.ERROR, description: 'Poly 线宽不小于 24nm', enabled: true },
    { id: 'MS_M1', name: '金属1最小间距', type: DrcRuleType.MIN_SPACING, targetLayerNumber: -1,layerNumber: 1, value: 36, severity: DrcSeverity.ERROR, description: 'M1 间距不小于 36nm', enabled: true },
    { id: 'MS_M2', name: '金属2最小间距', type: DrcRuleType.MIN_SPACING, targetLayerNumber: -1,layerNumber: 2, value: 40, severity: DrcSeverity.ERROR, description: 'M2 间距不小于 40nm', enabled: true },
    { id: 'MS_Poly', name: '多晶硅最小间距', type: DrcRuleType.MIN_SPACING, targetLayerNumber: -1,layerNumber: 4, value: 30, severity: DrcSeverity.ERROR, description: 'Poly 间距不小于 30nm', enabled: true },
    { id: 'MA_M1', name: '金属1最小面积', type: DrcRuleType.MIN_AREA, targetLayerNumber: -1, layerNumber: 1, value: 1296, severity: DrcSeverity.WARNING, description: 'M1 面积不小于 1296nm² (36x36)', enabled: true },
    { id: 'MA_AA', name: '有源区最小面积', type: DrcRuleType.MIN_AREA, targetLayerNumber: -1, layerNumber: 5, value: 576, severity: DrcSeverity.WARNING, description: 'AA 面积不小于 576nm² (24x24)', enabled: true },
    { id: 'ME_Poly_AA', name: '多晶硅超出有源区包围', type: DrcRuleType.MIN_ENCLOSURE, layerNumber: 4, targetLayerNumber: 5, value: 10, severity: DrcSeverity.WARNING, description: 'Poly 应超出 AA 边缘至少 10nm', enabled: true },
    { id: 'DEN_M1', name: '金属1最小密度', type: DrcRuleType.DENSITY, targetLayerNumber: -1, layerNumber: 1, value: 15, severity: DrcSeverity.WARNING, description: 'M1 窗口覆盖率不低于 15%', enabled: true },
  ],
};

/** Public SKY130 rules, three met1 checks only; not a qualified foundry rule deck.
 * https://skywater-pdk.readthedocs.io/en/main/rules/periphery.html#m1
 * https://skywater-pdk.readthedocs.io/en/main/rules/layers.html (met1 drawing 68/20)
 * 0.140 um = 140 nm; 0.083 um^2 = 83000 nm^2.
 */
export const RULESET_SKY130_MET1: DrcRuleset = {
  name: 'SKY130 M1子集',
  process: 'sky130-met1-public',
  rules: [
    { id: 'm1.1', name: 'SKY130 met1 最小宽度', type: DrcRuleType.MIN_WIDTH, layerNumber: 68, datatype: 20, targetLayerNumber: -1, value: 140, severity: DrcSeverity.ERROR, description: '公开规则 m1.1：68/20，0.140µm。仅三条几何规则子集，非签核。', enabled: true },
    { id: 'm1.2', name: 'SKY130 met1 最小间距', type: DrcRuleType.MIN_SPACING, layerNumber: 68, datatype: 20, targetLayerNumber: -1, value: 140, severity: DrcSeverity.ERROR, description: '公开规则 m1.2：68/20，0.140µm。不含 huge_met1 特例及其他规则。', enabled: true },
    { id: 'm1.6', name: 'SKY130 met1 最小面积', type: DrcRuleType.MIN_AREA, layerNumber: 68, datatype: 20, targetLayerNumber: -1, value: 83000, severity: DrcSeverity.ERROR, description: '公开规则 m1.6：68/20，0.083µm² = 83000nm²。非完整 PDK。', enabled: true },
  ],
};

/** 所有预设规则集 */
export const ALL_RULESETS: DrcRuleset[] = [RULESET_28NM, RULESET_14NM, RULESET_7NM, RULESET_SKY130_MET1];

/**
 * 读取规则清单文件的**原始文本**（唯一的文件 IO 职责；解析交给纯函数
 * `common/drcRuleText.ets::parseRuleSetText`，这样「粘贴文本」与「选中的 .json/CSV 文件」
 * 走同一套解析与同一套中文错误文案，不再有两份解析器）。
 *
 * 历史：本文件原有一份 `loadRulesetFromFile`，它对未知 type 静默降级成 min_width、
 * 对非法图层静默取 1——「规则装载失败」因此会变成「装了一条你没写的规则」。现已删除。
 *
 * @param path 规则文件绝对路径
 * @returns 文件文本；文件不存在 / 读失败 / 空文件时返回空串（由调用方给出中文提示）
 */
export function readRuleFileText(path: string): string {
  try {
    const fd = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const stat = fs.statSync(path);
    const size = stat.size;
    if (size <= 0) {
      fs.closeSync(fd);
      return '';
    }
    const buf = new ArrayBuffer(size);
    fs.readSync(fd.fd, buf, { length: size });
    fs.closeSync(fd);
    return decodeUtf8(buf);
  } catch (e) {
    console.warn('readRuleFileText failed for ' + path + ': ' + e);
    return '';
  }
}

/** 简易 UTF-8 解码（避免依赖 TextDecoder 兼容性） */
function decodeUtf8(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let result = '';
  let i = 0;
  while (i < bytes.length) {
    const b1 = bytes[i++];
    if (b1 < 0x80) {
      result += String.fromCharCode(b1);
    } else if (b1 < 0xE0) {
      const b2 = bytes[i++];
      result += String.fromCharCode(((b1 & 0x1F) << 6) | (b2 & 0x3F));
    } else if (b1 < 0xF0) {
      const b2 = bytes[i++];
      const b3 = bytes[i++];
      result += String.fromCharCode(((b1 & 0x0F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F));
    } else {
      const b2 = bytes[i++];
      const b3 = bytes[i++];
      const b4 = bytes[i++];
      const code = ((b1 & 0x07) << 18) | ((b2 & 0x3F) << 12) | ((b3 & 0x3F) << 6) | (b4 & 0x3F);
      // 转为 UTF-16 代理对
      const adjusted = code - 0x10000;
      result += String.fromCharCode(0xD800 + (adjusted >> 10), 0xDC00 + (adjusted & 0x3FF));
    }
  }
  return result;
}
