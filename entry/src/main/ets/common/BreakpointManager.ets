/**
 * 鸿图多设备断点管理器
 *
 * 基于 HarmonyOS NEXT 的栅格断点系统（sm/md/lg），
 * 实现三栏布局在不同设备上的自适应：
 *
 * - PC / 2in1 (lg, ≥1280vp)：完整三栏（导航 + 画布 + 图层面板）
 * - 平板 (md, 600-1279vp)：折叠导航 + 画布 + 抽屉式图层面板
 * - 手机 (sm, <600vp)：单画布 + 底部工具栏 + 弹出式面板
 *
 * 遵循 HarmonyOS "一多两全" 设计原则。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

/** 设备类型 */
export enum DeviceType {
  /** 手机 (< 768vp) */
  PHONE = 'phone',
  /** 平板 (768-1279vp) */
  TABLET = 'tablet',
  /** PC / 2in1 (≥ 1280vp) */
  PC = 'pc',
}

/** 断点宽度（与 PRD 4.4 响应式适配阈值对齐：手机 <768，平板 768-1280，桌面 ≥1280） */
export const BREAKPOINT_SM = 768;
export const BREAKPOINT_MD = 1280;

/** 布局配置 */
export interface LayoutConfig {
  device: DeviceType;
  /** 左侧导航栏宽度 (vp) */
  navWidth: number;
  /** 右侧面板宽度 (vp) */
  panelWidth: number;
  /** 是否显示左侧导航栏 */
  showNav: boolean;
  /** 是否显示右侧面板 */
  showPanel: boolean;
  /** 导航栏是否折叠为图标 */
  navCollapsed: boolean;
  /** 右侧面板是否为抽屉模式 */
  panelAsDrawer: boolean;
  /** 是否显示底部工具栏 */
  showBottomToolbar: boolean;
  /** 工具栏模式 */
  toolbarMode: ToolbarMode;
}

/** 工具栏模式 */
export enum ToolbarMode {
  /** 顶部水平工具栏（PC） */
  TOP_HORIZONTAL = 'top_horizontal',
  /** 左侧垂直工具栏（平板） */
  LEFT_VERTICAL = 'left_vertical',
  /** 底部水平工具栏（手机） */
  BOTTOM_HORIZONTAL = 'bottom_horizontal',
}

/**
 * 根据窗口宽度获取布局配置
 */
export function getLayoutConfig(widthVp: number): LayoutConfig {
  if (widthVp >= BREAKPOINT_MD) {
    // PC / 2in1
    return {
      device: DeviceType.PC,
      navWidth: 220,
      panelWidth: 280,
      showNav: true,
      showPanel: true,
      navCollapsed: false,
      panelAsDrawer: false,
      showBottomToolbar: false,
      toolbarMode: ToolbarMode.TOP_HORIZONTAL,
    };
  } else if (widthVp >= BREAKPOINT_SM) {
    // 平板
    return {
      device: DeviceType.TABLET,
      navWidth: 220,
      panelWidth: 280,
      showNav: true,
      showPanel: false,
      navCollapsed: false,
      panelAsDrawer: true,
      showBottomToolbar: false,
      toolbarMode: ToolbarMode.LEFT_VERTICAL,
    };
  } else {
    // 手机
    return {
      device: DeviceType.PHONE,
      navWidth: 0,
      panelWidth: 0,
      showNav: false,
      showPanel: false,
      navCollapsed: true,
      panelAsDrawer: true,
      showBottomToolbar: true,
      toolbarMode: ToolbarMode.BOTTOM_HORIZONTAL,
    };
  }
}

/**
 * 断点管理器
 *
 * 监听窗口尺寸变化，提供响应式布局配置。
 */
export class BreakpointManager {
  private currentWidth: number = 1280;
  private currentConfig: LayoutConfig;
  private listeners: ((config: LayoutConfig) => void)[] = [];

  constructor() {
    this.currentConfig = getLayoutConfig(this.currentWidth);
  }

  /** 更新窗口宽度 */
  updateWidth(widthVp: number) {
    const newConfig = getLayoutConfig(widthVp);
    const oldConfig = this.currentConfig;

    // 仅在设备类型变化时通知
    if (newConfig.device !== oldConfig.device) {
      this.currentWidth = widthVp;
      this.currentConfig = newConfig;
      this.notifyListeners();
    } else {
      this.currentWidth = widthVp;
      this.currentConfig = newConfig;
    }
  }

  /** 获取当前布局配置 */
  getConfig(): LayoutConfig {
    return this.currentConfig;
  }

  /** 获取当前设备类型 */
  getDevice(): DeviceType {
    return this.currentConfig.device;
  }

  /** 是否为 PC */
  isPC(): boolean {
    return this.currentConfig.device === DeviceType.PC;
  }

  /** 是否为平板 */
  isTablet(): boolean {
    return this.currentConfig.device === DeviceType.TABLET;
  }

  /** 是否为手机 */
  isPhone(): boolean {
    return this.currentConfig.device === DeviceType.PHONE;
  }

  /** 添加布局变化监听器 */
  addListener(listener: (config: LayoutConfig) => void) {
    this.listeners.push(listener);
  }

  /** 移除监听器 */
  removeListener(listener: (config: LayoutConfig) => void) {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private notifyListeners() {
    for (const listener of this.listeners) {
      listener(this.currentConfig);
    }
  }
}

/** 断点管理器单例 */
export const breakpointManager = new BreakpointManager();
