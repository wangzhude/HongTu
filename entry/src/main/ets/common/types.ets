/**
 * 鸿图公共类型定义
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

/** 场景导航模块 */
export enum NavModule {
  /** 版图编辑 */
  LAYOUT_EDIT = 0,
  /** 验证检查 */
  VERIFY = 1,
  /** 数据管理 */
  DATA_MGMT = 2,
}

/** 绘制工具 */
export enum DrawTool {
  /** 选择 */
  SELECT = 0,
  /** 矩形 */
  RECT = 1,
  /** 多边形 */
  POLYGON = 2,
  /** 路径 */
  PATH = 3,
  /** 测量 */
  MEASURE = 4,
  /** 文本标注 */
  TEXT = 5,
  /** 实例放置 */
  INSTANCE = 6,
  /** 标尺 */
  RULER = 7,
  /** 顶点编辑 */
  VERTEX_EDIT = 8,
  /** 两点移动 */
  MOVE = 9,
  /** 单指视口抓手漫游 */
  PAN = 10,
}

/** 视图模式（对应 KLayout 的 viewer / editor 模式分离） */
export enum ViewMode {
  /** 查看模式：只读，禁用所有改库操作，内存占用低 */
  VIEWER = 'viewer',
  /** 编辑模式：可创建/删除/修改图形（默认） */
  EDIT = 'edit',
}

/** 图层分组类型 */
export enum LayerGroup {
  /** 互连层 */
  INTERCONNECT = '互连层',
  /** 掺杂层 */
  DOPING = '掺杂层',
  /** 接触孔 */
  CONTACT = '接触孔',
  /** 其他 */
  OTHER = '其他',
}

/** UI 图层数据模型 */
export interface UiLayer {
  /** 图层编号 */
  layerNumber: number;
  /** 数据类型 */
  datatype: number;
  /** 中文名称 */
  chineseName: string;
  /** File layer name; independent of UI display aliases and layer/datatype identity. */
  sourceName?: string;
  /** 英文缩写 */
  englishName: string;
  /** 显示颜色 */
  color: string;
  /** 是否可见 */
  visible: boolean;
  /** 是否锁定（锁定后不可编辑该层图形） */
  locked?: boolean;
  /** 图形数量 */
  elementCount: number;
  /** 所属分组 */
  group: LayerGroup;
  /** 线型（solid/dashed/dotted/dotdash） */
  lineStyle?: string;
  /** 填充模式（solid/outline/cross/diagonal/hollow） */
  fillStyle?: string;
  /** 透明度 0-100 */
  transparency?: number;
  /** 线宽（像素） */
  lineWidth?: number;
  /** 是否选中（仅该图层可选） */
  selectable?: boolean;
  /** 是否加亮显示 */
  highlighted?: boolean;
  /** 动画效果（闪烁等） */
  animated?: boolean;
}

/** 选中图形的属性信息 */
export interface SelectionInfo {
  /** 图形类型 */
  type: string;
  /** 所在图层 */
  layer: string;
  /** X 坐标 (nm) */
  x: number;
  /** Y 坐标 (nm) */
  y: number;
  /** 宽度 (nm) */
  width: number;
  /** 高度 (nm) */
  height: number;
  /** 面积 (nm²) */
  area: number;
}

/** 文件加载状态 */
export enum LoadStatus {
  IDLE = 'idle',
  PARSING = 'parsing',
  LOADING = 'loading',
  DONE = 'done',
  ERROR = 'error',
}

/** 文件加载进度信息 */
export interface LoadProgress {
  status: LoadStatus;
  /** 当前已加载图形数 */
  loaded: number;
  /** 总图形数 */
  total: number;
  /** 进度百分比 0-100 */
  percent: number;
  /** 预计剩余时间（秒） */
  estimatedRemaining: number;
  /** 已用时间（秒） */
  elapsed: number;
  /** 跳过的图形数 */
  skipped: number;
  /** 错误信息 */
  error: string;
}

/** 鸿图核心版本信息 */
export interface AppInfo {
  version: string;
  buildDate: string;
  license: string;
  upstream: string;
}
