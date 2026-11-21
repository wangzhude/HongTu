/**
 * 鸿图 Demo 模式解析策略 (Fix ⑪)
 *
 * 将原 demoParse() 200+ 行单体函数拆分为策略模式：
 * - TemplateStrategy: 电路单元模板（反相器/NAND/NOR/传输门/SRAM）
 * - DrawStrategy: 几何创建（矩形/阵列/路径/多边形）
 * - EditStrategy: 编辑操作（移动/删除/旋转/对齐）
 * - ViewStrategy: 视口操作（缩放/适配/图层切换/可见性/工具）
 * - DrcStrategy: DRC 检查
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { AiCommandType, AiContext, ParsedCommand, CommandParams } from './AiService';

/** 解析策略接口 */
export interface ParseStrategy {
  /** 尝试匹配并解析，返回命令列表（空数组表示未匹配） */
  parse(text: string, context: AiContext): ParsedCommand[];
}

/** 图层名查找辅助 */
function findLayerByName(name: string, context: AiContext): number {
  const lower = name.toLowerCase().trim();
  for (const l of context.layers) {
    if (l.chineseName.includes(name) || l.englishName.toLowerCase().includes(lower)) {
      return l.layerNumber;
    }
  }
  const num = parseInt(name);
  return isNaN(num) ? -1 : num;
}

function layerName(layer: number, context: AiContext): string {
  const l = context.layers.find(l => l.layerNumber === layer);
  return l ? `${l.chineseName}(L${layer})` : `L${layer}`;
}

function parseLayer(text: string, context: AiContext): number | null {
  const m = text.match(/(?:图层|层)\s*(\d+)/);
  if (m) return parseInt(m[1]);
  const m2 = text.match(/金属\s*(\d)/);
  if (m2) {
    const idx = context.layers.findIndex(l => l.englishName === `M${m2[1]}`);
    return idx >= 0 ? context.layers[idx].layerNumber : null;
  }
  const englishLayer = text.match(/(?:^|[^A-Za-z0-9])([ML])\s*(\d+)(?:$|[^A-Za-z0-9])/i);
  if (englishLayer) {
    const prefix = englishLayer[1].toUpperCase();
    const number = englishLayer[2];
    const targetName = `${prefix}${number}`;
    const idx = context.layers.findIndex(l => l.englishName.toUpperCase() === targetName);
    if (idx >= 0) {
      return context.layers[idx].layerNumber;
    }
    if (prefix === 'L') {
      return parseInt(number);
    }
  }
  return null;
}

interface Position {
  x: number;
  y: number;
}

function parsePosition(text: string): Position | null {
  const m = text.match(/\(?(-?\d+)\s*,\s*(-?\d+)\)?/);
  if (m) {
    const p: Position = { x: parseInt(m[1]), y: parseInt(m[2]) };
    return p;
  }
  return null;
}

// ===== 模板策略 =====
export class TemplateStrategy implements ParseStrategy {
  parse(text: string, context: AiContext): ParsedCommand[] {
    if (/反相器|inverter/i.test(text)) return this.buildInverter(context);
    if (/与非门|nand/i.test(text)) return this.buildNand2(context);
    if (/或非门|nor/i.test(text)) return this.buildNor2(context);
    if (/传输门|transmission/i.test(text)) return this.buildTransmissionGate(context);
    if (/sram|存储单元|六管单元/i.test(text)) return this.buildSram(context);
    return [];
  }

  private buildInverter(ctx: AiContext): ParsedCommand[] {
    const m1 = ctx.layers.find(l => l.englishName === 'M1')?.layerNumber ?? 1;
    const poly = ctx.layers.find(l => l.englishName === 'Poly')?.layerNumber ?? 4;
    const aa = ctx.layers.find(l => l.englishName === 'AA')?.layerNumber ?? 5;
    const nwell = ctx.layers.find(l => l.englishName === 'NWell')?.layerNumber ?? 6;
    const via1 = ctx.layers.find(l => l.englishName === 'Via1')?.layerNumber ?? 10;
    return [
      { type: AiCommandType.CREATE_RECT, params: { layer: nwell, x: 0, y: 0, width: 400, height: 800 }, description: `N阱保护区 400×800nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: aa, x: 50, y: 400, width: 300, height: 200 }, description: `PMOS 有源区 300×200nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: aa, x: 50, y: 100, width: 300, height: 200 }, description: `NMOS 有源区 300×200nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 150, y: 50, width: 100, height: 600 }, description: `多晶硅栅（跨PMOS和NMOS）100×600nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: m1, x: 100, y: 300, width: 200, height: 100 }, description: `金属1 输入连线 200×100nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: via1, x: 180, y: 320, width: 40, height: 40 }, description: `通孔1 40×40nm` },
    ];
  }

  private buildNand2(ctx: AiContext): ParsedCommand[] {
    const m1 = ctx.layers.find(l => l.englishName === 'M1')?.layerNumber ?? 1;
    const poly = ctx.layers.find(l => l.englishName === 'Poly')?.layerNumber ?? 4;
    const aa = ctx.layers.find(l => l.englishName === 'AA')?.layerNumber ?? 5;
    return [
      { type: AiCommandType.CREATE_RECT, params: { layer: aa, x: 0, y: 0, width: 600, height: 300 }, description: `有源区 600×300nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 100, y: 0, width: 80, height: 300 }, description: `多晶硅栅 A 80×300nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 300, y: 0, width: 80, height: 300 }, description: `多晶硅栅 B 80×300nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: m1, x: 0, y: 100, width: 600, height: 100 }, description: `金属1 连线 600×100nm` },
    ];
  }

  private buildNor2(ctx: AiContext): ParsedCommand[] {
    const m1 = ctx.layers.find(l => l.englishName === 'M1')?.layerNumber ?? 1;
    const poly = ctx.layers.find(l => l.englishName === 'Poly')?.layerNumber ?? 4;
    const aa = ctx.layers.find(l => l.englishName === 'AA')?.layerNumber ?? 5;
    return [
      { type: AiCommandType.CREATE_RECT, params: { layer: aa, x: 0, y: 0, width: 600, height: 200 }, description: `PMOS 有源区 600×200nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: aa, x: 0, y: 250, width: 600, height: 200 }, description: `NMOS 有源区 600×200nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 100, y: 0, width: 80, height: 450 }, description: `多晶硅栅 A 80×450nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 300, y: 0, width: 80, height: 450 }, description: `多晶硅栅 B 80×450nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: m1, x: 380, y: 0, width: 100, height: 450 }, description: `金属1 输出 100×450nm` },
    ];
  }

  private buildTransmissionGate(ctx: AiContext): ParsedCommand[] {
    const m1 = ctx.layers.find(l => l.englishName === 'M1')?.layerNumber ?? 1;
    const poly = ctx.layers.find(l => l.englishName === 'Poly')?.layerNumber ?? 4;
    const aa = ctx.layers.find(l => l.englishName === 'AA')?.layerNumber ?? 5;
    return [
      { type: AiCommandType.CREATE_RECT, params: { layer: aa, x: 0, y: 0, width: 400, height: 300 }, description: `有源区 400×300nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 150, y: 0, width: 100, height: 300 }, description: `多晶硅栅 100×300nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: m1, x: 0, y: 100, width: 100, height: 100 }, description: `输入端 100×100nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: m1, x: 300, y: 100, width: 100, height: 100 }, description: `输出端 100×100nm` },
    ];
  }

  private buildSram(ctx: AiContext): ParsedCommand[] {
    const m1 = ctx.layers.find(l => l.englishName === 'M1')?.layerNumber ?? 1;
    const poly = ctx.layers.find(l => l.englishName === 'Poly')?.layerNumber ?? 4;
    const aa = ctx.layers.find(l => l.englishName === 'AA')?.layerNumber ?? 5;
    return [
      { type: AiCommandType.CREATE_RECT, params: { layer: aa, x: 0, y: 0, width: 800, height: 400 }, description: `SRAM 有源区 800×400nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 100, y: 0, width: 60, height: 400 }, description: `字线 WL1 60×400nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 300, y: 0, width: 60, height: 400 }, description: `字线 WL2 60×400nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 500, y: 0, width: 60, height: 400 }, description: `多晶硅栅 3 60×400nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: poly, x: 650, y: 0, width: 60, height: 400 }, description: `多晶硅栅 4 60×400nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: m1, x: 0, y: 150, width: 800, height: 100 }, description: `位线 BL/BLB 800×100nm` },
    ];
  }
}

// ===== 绘制策略 =====
export class DrawStrategy implements ParseStrategy {
  parse(text: string, context: AiContext): ParsedCommand[] {
    const commands: ParsedCommand[] = [];

    // 创建矩形
    const rectMatch = text.match(/(?:画|创建|绘制|添加|生成)\s*(?:一个)?[\s\S]*?(\d+)\s*[×x*]\s*(\d+)\s*(?:nm|纳米)?[\s\S]*?矩形/);
    if (rectMatch) {
      const w = parseInt(rectMatch[1]);
      const h = parseInt(rectMatch[2]);
      const layer = parseLayer(text, context) ?? context.currentLayer ?? 1;
      const defaultPos: Position = { x: 0, y: 0 };
      const pos = parsePosition(text) ?? defaultPos;
      commands.push({
        type: AiCommandType.CREATE_RECT,
        params: { layer, x: pos.x, y: pos.y, width: w, height: h },
        description: `在${layerName(layer, context)}层 (${pos.x},${pos.y}) 创建 ${w}×${h}nm 矩形`,
      });
    }

    const rectFromToMatch = text.match(/矩形.*?从\s*\(?(-?\d+)\s*,\s*(-?\d+)\)?\s*到\s*\(?(-?\d+)\s*,\s*(-?\d+)\)?/);
    if (rectFromToMatch) {
      const x1 = parseInt(rectFromToMatch[1]);
      const y1 = parseInt(rectFromToMatch[2]);
      const x2 = parseInt(rectFromToMatch[3]);
      const y2 = parseInt(rectFromToMatch[4]);
      const layer = parseLayer(text, context) ?? context.currentLayer ?? 1;
      const x = Math.min(x1, x2);
      const y = Math.min(y1, y2);
      const w = Math.abs(x2 - x1);
      const h = Math.abs(y2 - y1);
      commands.push({
        type: AiCommandType.CREATE_RECT,
        params: { layer, x, y, width: w, height: h },
        description: `在${layerName(layer, context)}层从 (${x1},${y1}) 到 (${x2},${y2}) 创建矩形`,
      });
    }

    const textMatch = text.match(/在\s*\(?(-?\d+)\s*,\s*(-?\d+)\)?\s*(?:添加|插入|创建)?\s*文本\s+(.+)$/);
    if (textMatch) {
      const x = parseInt(textMatch[1]);
      const y = parseInt(textMatch[2]);
      const label = textMatch[3].trim();
      const layer = parseLayer(text, context) ?? context.currentLayer ?? 1;
      if (label.length > 0) {
        commands.push({
          type: AiCommandType.CREATE_TEXT,
          params: { layer, x, y, text: label },
          description: `在${layerName(layer, context)}层 (${x},${y}) 添加文本 "${label}"`,
        });
      }
    }

    // 创建阵列
    const arrayMatch = text.match(/(\d+)\s*[×x*]\s*(\d+)\s*阵列.*?间距\s*(\d+)/);
    if (arrayMatch) {
      const rows = parseInt(arrayMatch[1]);
      const cols = parseInt(arrayMatch[2]);
      const spacing = parseInt(arrayMatch[3]);
      const layer = parseLayer(text, context) ?? context.currentLayer ?? 1;
      commands.push({
        type: AiCommandType.CREATE_ARRAY,
        params: { layer, x: 0, y: 0, width: 50, height: 50, rows, cols, spacingX: spacing, spacingY: spacing },
        description: `在${layerName(layer, context)}层创建 ${rows}×${cols} 阵列（间距 ${spacing}nm）`,
      });
    }

    return commands;
  }
}

// ===== 编辑策略 =====
export class EditStrategy implements ParseStrategy {
  parse(text: string, context: AiContext): ParsedCommand[] {
    const commands: ParsedCommand[] = [];

    // 移动
    if (/移动|上移|下移|左移|右移|平移/.test(text)) {
      const dx = this.parseOffset(text, ['右', '向东', 'east'], ['左', '向西', 'west']);
      const dy = this.parseOffset(text, ['上', '向上', '向北', 'north'], ['下', '向下', '向南', 'south']);
      if (dx !== 0 || dy !== 0) {
        commands.push({
          type: AiCommandType.MOVE_SHAPE,
          params: { dx, dy },
          description: `移动选中图形 (${dx >= 0 ? '+' : ''}${dx}, ${dy >= 0 ? '+' : ''}${dy}) nm`,
        });
      }
    }

    // 删除
    if (/删除|移除|去掉/.test(text) && /选中|当前/.test(text)) {
      commands.push({
        type: AiCommandType.DELETE_SHAPE,
        params: {},
        description: '删除选中的图形',
      });
    }

    // AICMD-2: 旋转（支持"旋转90度/旋转180/顺时针旋转270"等）
    const rotateMatch = text.match(/(?:旋转|顺时针旋转|逆时针旋转)\s*(?:顺时针|逆时针)?\s*(\d+)\s*度?/);
    if (rotateMatch) {
      const degrees: number = parseInt(rotateMatch[1]);
      const params: CommandParams = { degrees: degrees };
      commands.push({
        type: AiCommandType.ROTATE_SHAPE,
        params: params,
        description: `旋转选中图形 ${degrees}度`,
      });
    }

    // AICMD-2: 镜像（支持"水平镜像/垂直镜像/X轴翻转/Y轴翻转"）
    const mirrorMatch = text.match(/(水平|垂直|X轴|Y轴|横向|纵向)\s*(?:镜像|翻转)/);
    if (mirrorMatch) {
      // horizontal=1 表示沿 X 轴翻转（水平镜像），0 表示沿 Y 轴翻转（垂直镜像）
      const isHorizontal: boolean = /水平|X轴|横向/.test(mirrorMatch[1]);
      const params: CommandParams = { horizontal: isHorizontal ? 1 : 0 };
      commands.push({
        type: AiCommandType.MIRROR_SHAPE,
        params: params,
        description: `${mirrorMatch[1]}镜像选中图形`,
      });
    }

    // AICMD-2: 缩放（支持"缩放2倍/放大2倍/缩小0.5倍"）
    const scaleMatch = text.match(/(?:缩放|放大|缩小)\s*(\d+(?:\.\d+)?)\s*倍/);
    if (scaleMatch) {
      const factor: number = parseFloat(scaleMatch[1]);
      const params: CommandParams = { scale: factor };
      commands.push({
        type: AiCommandType.SCALE_SHAPE,
        params: params,
        description: `缩放选中图形 ${factor}x`,
      });
    }

    return commands;
  }

  private parseOffset(text: string, posKeys: string[], negKeys: string[]): number {
    for (const k of posKeys) {
      const m = text.match(new RegExp(`${k}\\s*(\\d+)`));
      if (m) return parseInt(m[1]);
    }
    for (const k of negKeys) {
      const m = text.match(new RegExp(`${k}\\s*(\\d+)`));
      if (m) return -parseInt(m[1]);
    }
    return 0;
  }
}

// ===== 视图策略 =====
export class ViewStrategy implements ParseStrategy {
  parse(text: string, context: AiContext): ParsedCommand[] {
    const commands: ParsedCommand[] = [];

    // 缩放
    const zoomMatch = text.match(/(?:缩放|zoom\s*(?:in|out|to))\s*(\d+)/i);
    if (zoomMatch || /放大|缩小|zoom\s*in|zoom\s*out/i.test(text)) {
      const scale = zoomMatch ? parseInt(zoomMatch[1]) : /放大|zoom\s*in/i.test(text) ? 1000 : 200;
      commands.push({
        type: AiCommandType.ZOOM,
        params: { scale },
        description: `缩放到 1:${scale}`,
      });
    }

    // 适配全部
    if (/适配|全屏|fit\s*all/i.test(text)) {
      commands.push({
        type: AiCommandType.FIT_ALL,
        params: {},
        description: '适配全部图形到视口',
      });
    }

    // 图层切换
    const selectLayerMatch = text.match(/(?:选中|选择|切换)(?:.*?到)?\s*(.+?)层/);
    if (selectLayerMatch) {
      const layer = findLayerByName(selectLayerMatch[1], context);
      if (layer >= 0) {
        commands.push({
          type: AiCommandType.SELECT_LAYER,
          params: { layer },
          description: `切换到${layerName(layer, context)}层`,
        });
      }
    }

    // 图层可见性
    const visMatch = text.match(/(隐藏|显示|关闭|打开)\s*(.+?)层/);
    let visHandled: boolean = false;
    if (visMatch) {
      const layer = findLayerByName(visMatch[2], context);
      if (layer >= 0) {
        commands.push({
          type: AiCommandType.SET_LAYER_VISIBLE,
          params: { layer, visible: visMatch[1] === '显示' || visMatch[1] === '打开' },
          description: `${visMatch[1]} ${layerName(layer, context)} 层`,
        });
        visHandled = true;
      }
    }

    // 直接可见性（如"隐藏 M3"）：仅当未命中 visMatch 时执行，避免双重匹配重复命令
    if (!visHandled) {
      const directVisMatch = text.match(/(隐藏|显示|关闭|打开)\s*([^，,。；;]+)/);
      if (directVisMatch) {
        const visible = directVisMatch[1] === '显示' || directVisMatch[1] === '打开';
        const layers = this.findMentionedLayers(directVisMatch[2], context);
        for (let i = 0; i < layers.length; i++) {
          commands.push({
            type: AiCommandType.SET_LAYER_VISIBLE,
            params: { layer: layers[i], visible },
            description: `${directVisMatch[1]} ${layerName(layers[i], context)} 层`,
          });
        }
      }
    }

    const onlyIndex = text.indexOf('只看');
    if (onlyIndex >= 0) {
      const keepLayers = this.findMentionedLayers(text.substring(onlyIndex + 2), context);
      if (keepLayers.length > 0) {
        for (let i = 0; i < context.layers.length; i++) {
          const layer = context.layers[i].layerNumber;
          commands.push({
            type: AiCommandType.SET_LAYER_VISIBLE,
            params: { layer, visible: this.containsLayer(keepLayers, layer) },
            description: `${this.containsLayer(keepLayers, layer) ? '显示' : '隐藏'} ${layerName(layer, context)} 层`,
          });
        }
      }
    }

    const tool = this.parseTool(text);
    if (tool.length > 0) {
      commands.push({
        type: AiCommandType.SET_TOOL,
        params: { tool },
        description: `切换到 ${tool} 工具`,
      });
    }

    return commands;
  }

  private findMentionedLayers(text: string, context: AiContext): number[] {
    const result: number[] = [];
    const lower = text.toLowerCase();
    for (let i = 0; i < context.layers.length; i++) {
      const layer = context.layers[i];
      const english = layer.englishName.toLowerCase();
      const aliases: string[] = [
        english,
        `l${layer.layerNumber}`,
        layer.chineseName,
      ];
      const metal = english.match(/^m(\d+)$/);
      if (metal) {
        aliases.push(`金属${metal[1]}`);
        aliases.push(`金属 ${metal[1]}`);
      }
      const via = english.match(/^via(\d+)$/);
      if (via) {
        aliases.push(`通孔${via[1]}`);
        aliases.push(`通孔 ${via[1]}`);
      }
      for (let j = 0; j < aliases.length; j++) {
        const alias = aliases[j];
        const matched = alias.length > 0 &&
          (lower.includes(alias.toLowerCase()) || text.includes(alias));
        if (matched && !this.containsLayer(result, layer.layerNumber)) {
          result.push(layer.layerNumber);
          break;
        }
      }
    }
    return result;
  }

  private containsLayer(layers: number[], layer: number): boolean {
    for (let i = 0; i < layers.length; i++) {
      if (layers[i] === layer) {
        return true;
      }
    }
    return false;
  }

  private parseTool(text: string): string {
    if (!/工具|tool|切换到|使用|用/.test(text)) {
      return '';
    }
    if (/选择|select/i.test(text)) {
      return 'select';
    }
    if (/矩形|rect/i.test(text)) {
      return 'rect';
    }
    if (/多边形|polygon/i.test(text)) {
      return 'polygon';
    }
    if (/路径|path/i.test(text)) {
      return 'path';
    }
    if (/测量|measure/i.test(text)) {
      return 'measure';
    }
    if (/文本|文字|text/i.test(text)) {
      return 'text';
    }
    if (/移动|move/i.test(text)) {
      return 'move';
    }
    if (/实例|instance/i.test(text)) {
      return 'instance';
    }
    return '';
  }
}

// ===== DRC 策略 =====
export class DrcStrategy implements ParseStrategy {
  parse(text: string, context: AiContext): ParsedCommand[] {
    if (/运行|执行|检查\s*DRC|设计规则/i.test(text)) {
      return [{
        type: AiCommandType.RUN_DRC,
        params: {},
        description: '运行 DRC 设计规则检查',
      }];
    }
    return [];
  }
}

/** 策略管理器 — 按优先级依次尝试匹配 */
export class DemoParseManager {
  private strategies: ParseStrategy[] = [
    new TemplateStrategy(),  // 模板优先
    new DrcStrategy(),       // DRC 快速匹配
    new DrawStrategy(),      // 绘制
    new EditStrategy(),      // 编辑
    new ViewStrategy(),      // 视图
  ];

  parse(text: string, context: AiContext): ParsedCommand[] {
    for (const strategy of this.strategies) {
      const commands = strategy.parse(text, context);
      if (commands.length > 0) {
        return commands;
      }
    }
    return [];
  }
}

/** 单例 */
export const demoParseManager = new DemoParseManager();
