import { ActiveTool, DrcIssue, RecentFile, ToolEntry } from './WorkbenchModels';
import { UiLayer, LayerGroup } from '../common/types';
import { LAYER_NAME_MAP } from '../common/constants';

export function createToolEntries(): ToolEntry[] {
  return [
    new ToolEntry(ActiveTool.Select, '⌖', '选择', 'XZ'),
    new ToolEntry(ActiveTool.Move, '↔', '移动', 'YD'),
    new ToolEntry(ActiveTool.Rect, '▭', '矩形', 'JX'),
    new ToolEntry(ActiveTool.Polygon, '◇', '多边形', 'DB'),
    new ToolEntry(ActiveTool.Path, '╱', '路径', 'LJ'),
    new ToolEntry(ActiveTool.Instance, '⊞', '放置实例', 'SF'),
    new ToolEntry(ActiveTool.Measure, '↔', '测量', 'CL'),
    new ToolEntry(ActiveTool.Text, 'T', '文本', 'WB'),
  ];
}

export function createInitialLayers(): UiLayer[] {
  // H-1/M-4: 从 LAYER_NAME_MAP 派生默认图层，保证与加载真实文件后的颜色/名称/分组一致
  const layers: UiLayer[] = [];
  const layerNumbers: number[] = [1, 2, 3, 4, 5, 6, 7, 10, 11, 12];
  for (let i = 0; i < layerNumbers.length; i++) {
    const layerNumber: number = layerNumbers[i];
    const entry = LAYER_NAME_MAP.get(layerNumber);
    if (entry) {
      const layer: UiLayer = {
        layerNumber: layerNumber,
        datatype: 0,
        chineseName: entry.chinese,
        englishName: entry.english,
        color: entry.color,
        visible: true,
        elementCount: 0,
        group: entry.group,
      };
      layers.push(layer);
    }
  }
  return layers;
}

export function createDrcIssues(): DrcIssue[] {
  return [];
}

export function createRecentFiles(): RecentFile[] {
  return [];
}

export function cloneLayerWithVisible(layer: UiLayer, visible: boolean): UiLayer {
  // M-1: 复制全部字段（含可选字段），避免切换可见性时丢失 lineStyle/fillStyle 等配置
  const next: UiLayer = {
    layerNumber: layer.layerNumber,
    datatype: layer.datatype,
    chineseName: layer.chineseName,
    englishName: layer.englishName,
    color: layer.color,
    visible: visible,
    elementCount: layer.elementCount,
    group: layer.group,
  };
  // 复制可选字段（若已赋值）
  if (layer.lineStyle !== undefined) next.lineStyle = layer.lineStyle;
  if (layer.fillStyle !== undefined) next.fillStyle = layer.fillStyle;
  if (layer.transparency !== undefined) next.transparency = layer.transparency;
  if (layer.lineWidth !== undefined) next.lineWidth = layer.lineWidth;
  if (layer.selectable !== undefined) next.selectable = layer.selectable;
  if (layer.locked !== undefined) next.locked = layer.locked;
  if (layer.highlighted !== undefined) next.highlighted = layer.highlighted;
  if (layer.animated !== undefined) next.animated = layer.animated;
  if (layer.sourceName !== undefined) next.sourceName = layer.sourceName;
  return next;
}
