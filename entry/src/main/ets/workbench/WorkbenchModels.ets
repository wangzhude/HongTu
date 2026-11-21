/**
 * Workbench domain models used by the HarmonyOS UI shell.
 */

/** 检查器标签页：图层 / 属性 / DRC */
export type InspectorTab = 'layer' | 'property' | 'drc';

/** 默认网格尺寸 */
export const DEFAULT_GRID_SIZE: number = 10;

export enum WorkModule {
  Layout = 'layout',
  Verify = 'verify',
  Data = 'data',
}

export enum ActiveTool {
  BoxZoom = 'boxZoom',
  Select = 'select',
  Pan = 'pan',
  Rect = 'rect',
  Polygon = 'polygon',
  Path = 'path',
  Measure = 'measure',
  Text = 'text',
  Move = 'move',
  /** 实例放置：选中后弹出 GUI 弹窗（不进入画布交互态） */
  Instance = 'instance',
}

export class ToolEntry {
  id: ActiveTool;
  icon: string;
  label: string;
  shortcut: string;

  constructor(id: ActiveTool, icon: string, label: string, shortcut: string) {
    this.id = id;
    this.icon = icon;
    this.label = label;
    this.shortcut = shortcut;
  }

  key(): string {
    return this.id;
  }
}

export class DrcIssue {
  id: number;
  ruleId: string;
  severity: string;
  ruleName: string;
  layerName: string;
  message: string;
  x: number;
  y: number;
  width: number;
  height: number;

  constructor(
    id: number,
    severity: string,
    ruleName: string,
    layerName: string,
    message: string,
    x: number,
    y: number,
    width: number = 0,
    height: number = 0,
    ruleId: string = ''
  ) {
    this.id = id;
    this.ruleId = ruleId;
    this.severity = severity;
    this.ruleName = ruleName;
    this.layerName = layerName;
    this.message = message;
    this.x = x;
    this.y = y;
    this.width = width;
    this.height = height;
  }

  key(): string {
    return this.id.toString();
  }
}

export class RecentFile {
  name: string;
  fileSizeLabel: string;
  fileType: string;
  sourceUri: string;
  sandboxPath: string;
  openedAt: number;
  topCellName?: string;
  cellCount?: number;
  elementCount?: number;

  constructor(
    name: string,
    fileSizeLabel: string,
    fileType: string,
    sourceUri: string = '',
    sandboxPath: string = '',
    openedAt: number = 0,
    topCellName?: string,
    cellCount?: number,
    elementCount?: number
  ) {
    this.name = name;
    this.fileSizeLabel = fileSizeLabel;
    this.fileType = fileType;
    this.sourceUri = sourceUri;
    this.sandboxPath = sandboxPath;
    this.openedAt = openedAt;
    this.topCellName = topCellName;
    this.cellCount = cellCount;
    this.elementCount = elementCount;
  }

  key(): string {
    if (this.sandboxPath.length > 0) {
      return this.sandboxPath;
    }
    if (this.sourceUri.length > 0) {
      return this.sourceUri;
    }
    return this.name;
  }
}
