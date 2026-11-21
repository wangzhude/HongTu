/**
 * 鸿图常量定义
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { DrawTool, LayerGroup, NavModule } from './types';
import { ThemeManager } from './Theme';

/** 应用信息 */
export const MIN_ZOOM_PERCENT: number = 0.0001;
export const MAX_ZOOM_PERCENT: number = 6400;

export const APP_NAME = '鸿图';
export const APP_NAME_EN = 'HongTu';
export const APP_VERSION = '0.1.0-dev';
export const APP_LICENSE = 'GPLv3';
export const APP_UPSTREAM = 'KLayout by Matthias Koefferlein';

/** 画布指针、双击微颤与矩形八手柄自适应热区常量（单位 vp） */
export const MOUSE_DRAG_SLOP_VP: number = 3;
export const TOUCH_DRAG_SLOP_VP: number = 10;
export const MOUSE_POLY_DBLCLICK_SLOP_VP: number = 8;
export const TOUCH_POLY_DBLCLICK_SLOP_VP: number = 16;
export const RECT_HANDLE_AUTO_MIN_SPAN_VP: number = 42;
export const RECT_HANDLE_FULL_HIT_SPAN_VP: number = 96;
export const RECT_INTERIOR_MOVE_MIN_RATIO: number = 0.44;

/** 主题颜色 */
export interface ColorPalette {
  // 品牌色
  primary: string;
  primarySoft: string;
  accent: string;
  accentSoft: string;
  // 语义色
  success: string;
  warning: string;
  danger: string;
  dangerSoft: string;
  teal: string;
  // 中性色
  bg: string;
  surface: string;
  surfaceMuted: string;
  border: string;
  ink: string;
  muted: string;
  // 画布色
  canvasBg: string;
  canvasGrid: string;
  canvasGridMajor: string;
}

/** 兼容别名：COLORS 现在是动态主题对象的代理引用（仍保持 ColorPalette 类型） */
export const COLORS: ColorPalette = ThemeManager.get();

/** 图层名映射条目 */
export interface LayerNameEntry {
  chinese: string;
  english: string;
  color: string;
  group: LayerGroup;
}

/**
 * 内置演示层号。GDS/OASIS 的 layer/datatype 原样导入；真实工艺的层号
 * 由文件及用户规则决定，不能从这张演示表推断电气连通。
 * C++ 内置 PCell/示例 DRC 的镜像定义见 cpp/demo_layers.h。
 */
export enum DemoLayerNumber {
  M1 = 1,
  M2 = 2,
  M3 = 3,
  POLY = 4,
  AA = 5,
  NWELL = 6,
  PWELL = 7,
  VIA1 = 10,
  VIA2 = 11,
  VIA3 = 12,
}

/** 内置演示图层的显示名映射；不代表 GDSII 标准层表。 */
export const LAYER_NAME_MAP: Map<number, LayerNameEntry> = new Map<number, LayerNameEntry>();
LAYER_NAME_MAP.set(DemoLayerNumber.M1,
  { chinese: '金属1', english: 'M1', color: '#007AFF', group: LayerGroup.INTERCONNECT });
LAYER_NAME_MAP.set(DemoLayerNumber.M2,
  { chinese: '金属2', english: 'M2', color: '#5856D6', group: LayerGroup.INTERCONNECT });
LAYER_NAME_MAP.set(DemoLayerNumber.M3,
  { chinese: '金属3', english: 'M3', color: '#AF52DE', group: LayerGroup.INTERCONNECT });
LAYER_NAME_MAP.set(DemoLayerNumber.POLY,
  { chinese: '多晶硅', english: 'Poly', color: '#FF3B30', group: LayerGroup.DOPING });
LAYER_NAME_MAP.set(DemoLayerNumber.AA,
  { chinese: '有源区', english: 'AA', color: '#34C759', group: LayerGroup.DOPING });
LAYER_NAME_MAP.set(DemoLayerNumber.NWELL,
  { chinese: 'N阱', english: 'NWell', color: '#AF52DE', group: LayerGroup.DOPING });
LAYER_NAME_MAP.set(DemoLayerNumber.PWELL,
  { chinese: 'P阱', english: 'PWell', color: '#BF5AF2', group: LayerGroup.DOPING });
LAYER_NAME_MAP.set(DemoLayerNumber.VIA1,
  { chinese: '通孔1', english: 'Via1', color: '#FF9F0A', group: LayerGroup.CONTACT });
LAYER_NAME_MAP.set(DemoLayerNumber.VIA2,
  { chinese: '通孔2', english: 'Via2', color: '#FFD60A', group: LayerGroup.CONTACT });
LAYER_NAME_MAP.set(DemoLayerNumber.VIA3,
  { chinese: '通孔3', english: 'Via3', color: '#FF375F', group: LayerGroup.CONTACT });

/** 仅在明确选择内置演示工艺时使用。Via3 未定义上层金属，不猜 M4。 */
export interface DemoViaLayer {
  viaLayer: number;
  lowerLayer: number;
  upperLayer: number;
}

export const DEMO_VIA_LAYERS: DemoViaLayer[] = [
  { viaLayer: DemoLayerNumber.VIA1, lowerLayer: DemoLayerNumber.M1, upperLayer: DemoLayerNumber.M2 },
  { viaLayer: DemoLayerNumber.VIA2, lowerLayer: DemoLayerNumber.M2, upperLayer: DemoLayerNumber.M3 },
];

/** 获取未知图层的默认颜色 */
export function getDefaultLayerColor(layerNumber: number): string {
  const palette = ['#007AFF', '#5856D6', '#34C759', '#FF3B30', '#AF52DE',
                   '#FF9F0A', '#FF375F', '#BF5AF2', '#FFD60A', '#64D2FF'];
  return palette[layerNumber % palette.length];
}

/**
 * 绘制工具快捷键映射（已迁移至 ShortcutService.DEFAULT_SHORTCUT_MAP 统一管理）。
 * 旧的 TOOL_SHORTCUTS 与 ShortcutService 存在双源冲突（'BC' 既绑保存又绑标尺、'DB' 既绑多边形又绑顶点编辑），
 * 已删除以消除"两套真相"。快捷键自定义、冲突检测、持久化请使用 ShortcutService。
 */

/** 绘制工具名称映射 */
export const TOOL_NAMES: Map<DrawTool, string> = new Map<DrawTool, string>([
  [DrawTool.SELECT, '选择'],
  [DrawTool.MOVE, '移动'],
  [DrawTool.RECT, '矩形'],
  [DrawTool.POLYGON, '多边形'],
  [DrawTool.PATH, '路径'],
  [DrawTool.MEASURE, '测量'],
  [DrawTool.TEXT, '文本标注'],
  [DrawTool.INSTANCE, '实例放置'],
  [DrawTool.RULER, '标尺'],
  [DrawTool.VERTEX_EDIT, '顶点编辑'],
]);

/** 图层线型枚举 */
export enum LayerLineStyle {
  SOLID = 'solid',
  DASHED = 'dashed',
  DOTTED = 'dotted',
  DOT_DASH = 'dotdash',
}

/** 图层填充模式枚举 */
export enum LayerFillStyle {
  SOLID = 'solid',
  OUTLINE = 'outline',
  CROSS = 'cross',
  DIAGONAL = 'diagonal',
  HOLLOW = 'hollow',
}

/** 预设颜色板（Apple 风格） */
export const LAYER_COLOR_PRESETS: string[] = [
  '#007AFF', '#5856D6', '#34C759', '#FF3B30', '#AF52DE',
  '#FF9F0A', '#FF375F', '#BF5AF2', '#FFD60A', '#64D2FF',
  '#30D158', '#FF6482', '#5E5CE6', '#FFB340', '#FF2D55',
  '#32ADE6', '#89D4FF', '#A2845E', '#AC8E68', '#BDAB41',
];

/** 导航模块名称映射 */
export const NAV_MODULE_NAMES: Map<NavModule, string> = new Map<NavModule, string>([
  [NavModule.LAYOUT_EDIT, '版图编辑'],
  [NavModule.VERIFY, '验证检查'],
  [NavModule.DATA_MGMT, '数据管理'],
]);

/** 大文件阈值：超过此大小打开时弹出"大版图打开向导"让用户选择查看/编辑模式并提示内存影响 */
export const LARGE_FILE_THRESHOLD_BYTES: number = 50 * 1024 * 1024; // 50 MB
/** 超大文件阈值：强烈建议以查看模式打开（OASIS 数组在编辑模式下会被展开成单个 shape，内存约 10 倍） */
export const HUGE_FILE_THRESHOLD_BYTES: number = 200 * 1024 * 1024; // 200 MB

/** 格式化文件大小 */
export function formatFileSize(bytes: number): string {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

/** 格式化图形数量（带 K/M 简写） */
export function formatCount(count: number): string {
  if (count >= 1000000) return (count / 1000000).toFixed(1) + 'M';
  if (count >= 1000) return (count / 1000).toFixed(1) + 'K';
  return count.toString();
}

// ===== 单位与坐标变换（§3 统一 DBU/屏幕/Y 轴） =====

/**
 * 世界坐标单位约定：内部一律 nm。
 * native 读取器已把 GDSII DBU 归一为 nm（dbu * physicalUnits * 1e9，见 gdsii_reader.cpp），
 * 因此 UI 层**不得**再次做 DBU 换算；µm 只在显示层经 nmToUm()/umText() 换算一次。
 */
export const NM_PER_UM: number = 1000;

/** nm → µm（全工程唯一的显示单位换算出口） */
export function nmToUm(nm: number): number {
  return nm / NM_PER_UM;
}

/** nm → µm 文本；默认 3 位小数即 1 nm 分辨率，亚 nm DBU 可加大 digits */
export function umText(nm: number, digits: number = 3): string {
  return nmToUm(nm).toFixed(digits);
}

/** 缩放百分比 → 线性倍率（下限防 0 除，与 CanvasGrid/视口裁剪同口径） */
function zoomFactor(zoomPercent: number): number {
  return Math.max(0.00001, zoomPercent) / 100;
}

/**
 * 世界 X(nm) → 屏幕像素：pixelX = (worldX + offsetX) * zoom/100。
 * 版图世界坐标为 Y 向上，Y 轴必须使用 worldToScreenYpx。
 */
export function worldToScreenPx(world: number, zoomPercent: number, offset: number): number {
  return (world + offset) * zoomFactor(zoomPercent);
}

/** 屏幕像素 → 世界坐标(nm)：worldToScreenPx 的严格逆函数 */
export function screenToWorldPx(pixel: number, zoomPercent: number, offset: number): number {
  return pixel / zoomFactor(zoomPercent) - offset;
}

/** 世界 Y(nm) 向上，屏幕像素向下；offsetY 是屏幕顶部对应的世界 Y。 */
export function worldToScreenYpx(world: number, zoomPercent: number, offset: number): number {
  return (offset - world) * zoomFactor(zoomPercent);
}

/** 屏幕 Y → 世界 Y：worldToScreenYpx 的严格逆函数。 */
export function screenToWorldYpx(pixel: number, zoomPercent: number, offset: number): number {
  return offset - pixel / zoomFactor(zoomPercent);
}

/**
 * 坐标变换自检：screen↔world 严格互逆 + X 向右/Y 向上 + µm 换算单次。
 * 仅组件 aboutToAppear 调一次，失败时由调用方 console.warn 暴露（本工程 ArkTS 侧无测试框架）。
 */
export function canvasTransformConsistent(): boolean {
  const zooms: number[] = [0.5, 25, 100, 400, 3200];
  const offsets: number[] = [0, -12345.5, 678.25];
  const worlds: number[] = [0, -1, 12.5, 1000000];
  for (let zi = 0; zi < zooms.length; zi++) {
    for (let oi = 0; oi < offsets.length; oi++) {
      const z: number = zooms[zi];
      const o: number = offsets[oi];
      for (let wi = 0; wi < worlds.length; wi++) {
        const w: number = worlds[wi];
        const back: number = screenToWorldPx(worldToScreenPx(w, z, o), z, o);
        if (Math.abs(back - w) > 1e-6) {
          return false;
        }
        const backY: number = screenToWorldYpx(worldToScreenYpx(w, z, o), z, o);
        if (Math.abs(backY - w) > 1e-6) {
          return false;
        }
      }
      // 世界 X 增大向右；世界 Y 增大向上（屏幕像素行号减小）。
      if (worldToScreenPx(1, z, o) <= worldToScreenPx(0, z, o)) {
        return false;
      }
      if (worldToScreenYpx(1, z, o) >= worldToScreenYpx(0, z, o)) {
        return false;
      }
    }
  }
  return umText(1000) === '1.000' && nmToUm(2500) === 2.5;
}

/** Keep camera precision while preventing fractional percentages from wrapping in controls. */
export function formatZoomPercent(percent: number): string {
  if (!Number.isFinite(percent) || percent <= 0) {
    return '0%';
  }
  if (percent < 0.01) {
    return `${Number(percent.toPrecision(2))}%`;
  }
  if (percent < 0.1) {
    return `${Number(percent.toFixed(3))}%`;
  }
  return `${Number(percent.toFixed(percent < 10 ? 2 : 1))}%`;
}
