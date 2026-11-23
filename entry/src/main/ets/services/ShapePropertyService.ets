import { Shape, ShapeType, Point, getShapeBounds, normalizePropRecords, MAX_PROPS_PER_OWNER } from '../models/GdsiiData';
import type { LayoutPropRecord } from '../../cpp/types/libhongtu/Index';

export interface PropertyCellOption { id: number; name: string; }
export interface PropertyEditResult { ok: boolean; changed: number; message: string; }
export interface ShapePropertyField { key: string; label: string; unit: string; }

export interface PCellPropertyMetadata {
  name: string; params: Record<string, number | string | boolean>;
  technologyId?: string; technologyVersion?: string; deviceName?: string; deviceModel?: string;
}

export interface DecodedPCellProperty { metadata: PCellPropertyMetadata; active: boolean; }

/** Plain markers follow the consumer's value-only rule; dtype7 hex is a separate wire form. */
export function decodePCellProperty(property: LayoutPropRecord): DecodedPCellProperty | undefined {
  if (property === null || property === undefined || typeof property.value !== 'string') return undefined;
  let text: string = property.value;
  const plainMarker: boolean = text.startsWith('HONGTU_PCELL_V1:') || text.startsWith('HONGTU_PCELL_FLAT_SOURCE_V1:');
  let hexCarrier: boolean = false;
  if (!plainMarker && property.dtype === 7) {
    if (text.length > 131061 || !/^#([0-9a-fA-F]{2})+$/.test(text)) return undefined;
    let decoded: string = '';
    for (let i: number = 1; i < text.length; i += 2) {
      const byte: number = Number.parseInt(text.substring(i, i + 2), 16);
      if (byte > 126) return undefined;
      decoded += String.fromCharCode(byte);
    }
    text = decoded;
    hexCarrier = true;
  }
  if (text.endsWith('\0')) {
    if (!hexCarrier || text.length % 2 !== 0) return undefined;
    text = text.substring(0, text.length - 1);
  }
  if (text.length > 65530) return undefined;
  const prefix: string = text.startsWith('HONGTU_PCELL_V1:') ? 'HONGTU_PCELL_V1:' :
    (text.startsWith('HONGTU_PCELL_FLAT_SOURCE_V1:') ? 'HONGTU_PCELL_FLAT_SOURCE_V1:' : '');
  if (prefix.length === 0) return undefined;
  try {
    const metadata: PCellPropertyMetadata = JSON.parse(text.substring(prefix.length)) as PCellPropertyMetadata;
    if (metadata === null || typeof metadata !== 'object' || Array.isArray(metadata) ||
      typeof metadata.name !== 'string' || metadata.name.length === 0 || metadata.name.length > 128 ||
      metadata.params === null || typeof metadata.params !== 'object' || Array.isArray(metadata.params)) return undefined;
    const identities: (string | undefined)[] = [metadata.technologyId, metadata.technologyVersion, metadata.deviceName, metadata.deviceModel];
    if (identities.some((value: string | undefined): boolean => value !== undefined) &&
      identities.some((value: string | undefined): boolean => typeof value !== 'string' || value.length === 0 ||
        value.length > 120 || value.includes('\0'))) return undefined;
    const keys: string[] = Object.keys(metadata.params);
    if (keys.length > 128) return undefined;
    if (!keys.every((key: string): boolean => {
      const value: number | string | boolean = metadata.params[key];
      return key.length <= 128 && ((typeof value === 'number' && Number.isFinite(value)) ||
        (typeof value === 'string' && value.length <= 4096) || typeof value === 'boolean');
    })) return undefined;
    return { metadata: metadata, active: prefix === 'HONGTU_PCELL_V1:' };
  } catch (_) { return undefined; }
}

function isProtectedPCellProperty(property: LayoutPropRecord): boolean {
  return decodePCellProperty(property) !== undefined;
}

/**
 * 合并布尔运算两个源图元的 GDS/OASIS 属性记录（去重并控制在 64 条上限内），
 * 将活动 PCell 标记降级为静态来源追溯标记，避免静态布尔多边形伪装成活动 PCell。
 */
export function mergeBooleanSourceProperties(
  primary: LayoutPropRecord[] | undefined,
  secondary?: LayoutPropRecord[] | undefined
): LayoutPropRecord[] | undefined {
  const merged: LayoutPropRecord[] = [];
  const seen: Set<string> = new Set<string>();
  const appendList = (list: LayoutPropRecord[] | undefined): void => {
    const clean: LayoutPropRecord[] | undefined = normalizePropRecords(list);
    if (clean === undefined) return;
    for (let i = 0; i < clean.length; i++) {
      if (merged.length >= MAX_PROPS_PER_OWNER) return;
      const item: LayoutPropRecord = clean[i];
      const decoded: DecodedPCellProperty | undefined = decodePCellProperty(item);
      let nextVal: string = item.value;
      let nextDtype: number = item.dtype;
      if (decoded !== undefined && decoded.active) {
        nextVal = `HONGTU_PCELL_FLAT_SOURCE_V1:${JSON.stringify(decoded.metadata)}`;
        if (nextDtype === 7) {
          nextDtype = 6;
        }
      }
      const key: string = `${item.attr}:${nextDtype}:${item.name}:${nextVal}`;
      if (seen.has(key)) continue;
      seen.add(key);
      merged.push({ attr: item.attr, dtype: nextDtype, name: item.name, value: nextVal });
    }
  };
  appendList(primary);
  appendList(secondary);
  return merged.length > 0 ? merged : undefined;
}

function cleanCoordStr(val: number): string {
  if (!Number.isFinite(val)) return '0';
  const rounded: number = Math.round(val * 1000) / 1000;
  return `${rounded}`;
}

/** Values are explicit so ArkTS never relies on dynamic object indexing. */
export function shapePropertyValue(s: Shape, key: string): string {
  const b = getShapeBounds(s);
  switch (key) {
    case 'x':
    case 'minXEdge': return `${b.minX}`;
    case 'y':
    case 'minYEdge': return `${b.minY}`;
    case 'maxX': return `${b.maxX}`;
    case 'maxY': return `${b.maxY}`;
    case 'centerX': return cleanCoordStr((b.minX + b.maxX) * 0.5);
    case 'centerY': return cleanCoordStr((b.minY + b.maxY) * 0.5);
    case 'width':
    case 'widthCenter': return `${b.maxX - b.minX}`;
    case 'height':
    case 'heightCenter': return `${b.maxY - b.minY}`;
    case 'layerKey': return `${s.layerNumber}/${s.datatype}`;
    case 'text': return s.text ?? '';
    case 'pathWidth': return `${s.pathWidth ?? 1}`;
    case 'pathType': return `${s.pathType ?? 0}`;
    case 'pathBeginExtension': return `${s.pathBeginExtension ?? 0}`;
    case 'pathEndExtension': return `${s.pathEndExtension ?? 0}`;
    case 'pathWidthAbsolute': return s.pathWidthAbsolute ? '1' : '0';
    case 'cellId': return `${s.cellId ?? -1}`;
    case 'rotation': return `${s.rotation ?? 0}`;
    case 'mirror': return `${s.mirror ?? 0}`;
    case 'magnification': return `${s.magnification ?? 1}`;
    case 'arrayCols': return `${s.arrayCols || 1}`;
    case 'arrayRows': return `${s.arrayRows || 1}`;
    case 'arrayColStepX': return `${s.arrayColStepX ?? 0}`;
    case 'arrayColStepY': return `${s.arrayColStepY ?? 0}`;
    case 'arrayRowStepX': return `${s.arrayRowStepX ?? 0}`;
    case 'arrayRowStepY': return `${s.arrayRowStepY ?? 0}`;
    case 'properties': return JSON.stringify((s.properties ?? []).filter((p: LayoutPropRecord) => !isProtectedPCellProperty(p)));
    default: return '';
  }
}

export function shapePropertyFields(type: ShapeType | null): ShapePropertyField[] {
  const isPointObject: boolean = type === ShapeType.TEXT || type === ShapeType.INSTANCE;
  const fields: ShapePropertyField[] = [
    { key: 'x', label: isPointObject ? '锚点 X' : '左下 X1', unit: 'nm' },
    { key: 'y', label: isPointObject ? '锚点 Y' : '左下 Y1', unit: 'nm' }
  ];
  if (type !== ShapeType.INSTANCE) fields.push({ key: 'layerKey', label: '层 / 数据型', unit: '' });
  if (type === ShapeType.RECT || type === ShapeType.POLYGON || type === ShapeType.PATH) {
    fields.push({ key: 'width', label: '宽度 W', unit: 'nm' }, { key: 'height', label: '高度 H', unit: 'nm' });
  }
  if (type === ShapeType.TEXT) fields.push({ key: 'text', label: '文本内容', unit: '' });
  if (type === ShapeType.PATH) {
    fields.push({ key: 'pathWidth', label: '路径线宽', unit: 'nm' },
      { key: 'pathType', label: '端型', unit: '0/1/2/4' },
      { key: 'pathBeginExtension', label: '起点延伸', unit: 'nm' },
      { key: 'pathEndExtension', label: '终点延伸', unit: 'nm' },
      { key: 'pathWidthAbsolute', label: '固定线宽', unit: '0/1' });
  }
  if (type === ShapeType.INSTANCE) {
    fields.push({ key: 'cellId', label: '引用 Cell ID', unit: '' },
      { key: 'arrayCols', label: '阵列列数', unit: '' }, { key: 'arrayRows', label: '阵列行数', unit: '' },
      { key: 'arrayColStepX', label: '列步进 X', unit: 'nm' }, { key: 'arrayColStepY', label: '列偏置 Y', unit: 'nm' },
      { key: 'arrayRowStepX', label: '行偏置 X', unit: 'nm' }, { key: 'arrayRowStepY', label: '行步进 Y', unit: 'nm' });
  }
  if (type === ShapeType.INSTANCE || type === ShapeType.TEXT) {
    fields.push({ key: 'rotation', label: '旋转', unit: '°' }, { key: 'mirror', label: '镜像', unit: '0/1/2' },
      { key: 'magnification', label: '倍率', unit: '×' });
  }
  return fields;
}

function checkPathZeroLengthCollapse(beforePoints: Point[], nextPoints: Point[]): string {
  for (let i = 1; i < nextPoints.length; i++) {
    const beforeA: Point = beforePoints[i - 1];
    const beforeB: Point = beforePoints[i];
    if ((beforeA.x !== beforeB.x || beforeA.y !== beforeB.y) &&
      nextPoints[i - 1].x === nextPoints[i].x &&
      nextPoints[i - 1].y === nextPoints[i].y) {
      return '修改会产生重合顶点（零长度边），请调整尺寸或顶点';
    }
  }
  return '';
}

function shapePathPadding(s: Shape): number {
  return s.type === ShapeType.PATH
    ? (s.pathWidth ?? 0) + ((s.pathType ?? 0) === 4 ? 2 * Math.max(Math.abs(s.pathBeginExtension ?? 0), Math.abs(s.pathEndExtension ?? 0)) : 0)
    : 0;
}

/** Mutates only a caller-owned clone. All targets must pass before committing. */
export function prepareShapeProperty(s: Shape, key: string, value: string,
  cells: PropertyCellOption[], allShapes: Shape[], topCellId: number = 0): string {
  if (key === 'properties') {
    try {
      const records: LayoutPropRecord[] = JSON.parse(value) as LayoutPropRecord[];
      if (!Array.isArray(records) || records.length > 64) return '属性必须是最多 64 项的 JSON 数组';
      const protectedRecords: LayoutPropRecord[] = (s.properties ?? []).filter((p: LayoutPropRecord) => isProtectedPCellProperty(p));
      const next: LayoutPropRecord[] = [];
      for (let i = 0; i < records.length; i++) {
        const r: LayoutPropRecord = records[i];
        if (r === null || typeof r !== 'object' || !Number.isInteger(r.attr) || r.attr < -32768 || r.attr > 32767 ||
          !Number.isInteger(r.dtype) || r.dtype < 0 || r.dtype > 255 ||
          typeof r.name !== 'string' || typeof r.value !== 'string') return `第 ${i + 1} 项需要 attr、dtype、name、value`;
        if (isProtectedPCellProperty(r)) return '器件参数记录请通过“修改参数”更新';
        if ((r.dtype === 7 || (r.dtype >= 2 && r.dtype <= 5 && r.value.startsWith('#'))) &&
          !/^#([0-9a-fA-F]{2})+$/.test(r.value)) return `第 ${i + 1} 项的二进制属性需要 # 开头的完整十六进制字节`;
        const bytes: number = (r.dtype === 7 || (r.dtype >= 2 && r.dtype <= 5 && r.value.startsWith('#'))) ?
          (r.value.length - 1) / 2 : utf8Length(r.value);
        if (!Number.isInteger(bytes) || bytes > 65530 || r.name.length > 65536) return `第 ${i + 1} 项超过 GDS 属性容量`;
        next.push({ attr: r.attr, dtype: r.dtype, name: r.name, value: r.value });
      }
      for (const property of protectedRecords) {
        next.push({ attr: property.attr, dtype: property.dtype, name: property.name, value: property.value });
      }
      if (next.length > 64) return '用户属性与器件参数记录合计不能超过 64 项';
      s.properties = next.length > 0 ? next : undefined;
      return '';
    } catch (_) { return '属性 JSON 无效，未修改任何对象'; }
  }
  if (key === 'text') {
    if (s.type !== ShapeType.TEXT) return '文本内容仅适用于 TEXT';
    s.text = value;
    return '';
  }
  if (key === 'layerKey') {
    if (s.type === ShapeType.INSTANCE) return '实例引用没有独立绘制图层';
    const pair: string[] = value.trim().split('/');
    const layer: number = Number(pair[0]); const datatype: number = Number(pair[1]);
    if (pair.length !== 2 || pair.some((p: string) => p.trim().length === 0) ||
      !Number.isInteger(layer) || layer < 0 || layer > 32767 ||
      !Number.isInteger(datatype) || datatype < 0 || datatype > 32767) return '请填写 0–32767 范围的 layer/datatype';
    s.layerNumber = layer; s.datatype = datatype;
    return '';
  }
  if (value.trim().length === 0) return '数值不能为空';
  const n: number = Number(value);
  if (!Number.isFinite(n)) return '请输入完整的有限数值';

  // 中心点平移（centerX / centerY）：整体平移图形使其包围盒中心精确落在目标坐标
  if (key === 'centerX' || key === 'centerY') {
    const b = getShapeBounds(s);
    const cx: number = (b.minX + b.maxX) * 0.5;
    const cy: number = (b.minY + b.maxY) * 0.5;
    const dx: number = key === 'centerX' ? n - cx : 0;
    const dy: number = key === 'centerY' ? n - cy : 0;
    s.points = s.points.map((p: Point): Point => ({ x: p.x + dx, y: p.y + dy }));
    return '';
  }

  // 中心点锚定对称缩放（widthCenter / heightCenter）：保持中心点 CX/CY 不变，向两侧对称缩放宽或高
  if (key === 'widthCenter' || key === 'heightCenter') {
    const b = getShapeBounds(s);
    const w: number = b.maxX - b.minX;
    const h: number = b.maxY - b.minY;
    const isW: boolean = key === 'widthCenter';
    if (s.type === ShapeType.TEXT || s.type === ShapeType.INSTANCE || n <= 0 || (isW ? w : h) <= 0) {
      return '宽高必须大于 0，且对象需要可缩放的几何';
    }
    const padding: number = shapePathPadding(s);
    const extent: number = (isW ? w : h) - padding;
    if (n < padding || (extent === 0 && n !== padding)) {
      return '该尺寸小于线宽/延伸，或路径在此方向没有跨度；请调整线宽或顶点';
    }
    const scale: number = extent === 0 ? 1 : (n - padding) / extent;
    const cx: number = (b.minX + b.maxX) * 0.5;
    const cy: number = (b.minY + b.maxY) * 0.5;
    const nextPoints: Point[] = s.points.map((p: Point): Point => ({
      x: isW ? cx + (p.x - cx) * scale : p.x,
      y: !isW ? cy + (p.y - cy) * scale : p.y,
    }));
    if (s.type === ShapeType.PATH) {
      const err: string = checkPathZeroLengthCollapse(s.points, nextPoints);
      if (err.length > 0) return err;
    }
    s.points = nextPoints;
    return '';
  }

  // 对角边界独立推拉（minXEdge / maxX / minYEdge / maxY，对齐 KLayout Box Left/Right/Bottom/Top 编辑语义）
  if (key === 'minXEdge' || key === 'maxX' || key === 'minYEdge' || key === 'maxY') {
    const b = getShapeBounds(s);
    if (s.type === ShapeType.TEXT || s.type === ShapeType.INSTANCE) {
      const dx: number = (key === 'minXEdge' || key === 'maxX') ? n - b.minX : 0;
      const dy: number = (key === 'minYEdge' || key === 'maxY') ? n - b.minY : 0;
      s.points = s.points.map((p: Point): Point => ({ x: p.x + dx, y: p.y + dy }));
      return '';
    }
    const w: number = b.maxX - b.minX;
    const h: number = b.maxY - b.minY;
    const isX: boolean = key === 'minXEdge' || key === 'maxX';
    const isMinEdge: boolean = key === 'minXEdge' || key === 'minYEdge';
    const targetSpan: number = isX
      ? (isMinEdge ? b.maxX - n : n - b.minX)
      : (isMinEdge ? b.maxY - n : n - b.minY);
    if (targetSpan <= 0) {
      return isX
        ? (isMinEdge ? '左边界 X1 必须小于右边界 X2' : '右边界 X2 必须大于左边界 X1')
        : (isMinEdge ? '下边界 Y1 必须小于上边界 Y2' : '上边界 Y2 必须大于下边界 Y1');
    }
    if ((isX ? w : h) <= 0) {
      return '对象在此方向跨度为 0，无法单独推拉边界';
    }
    const padding: number = shapePathPadding(s);
    const extent: number = (isX ? w : h) - padding;
    if (targetSpan < padding || (extent === 0 && targetSpan !== padding)) {
      return '边界间距小于路径线宽/延伸；请调整线宽或顶点';
    }
    const scale: number = extent === 0 ? 1 : (targetSpan - padding) / extent;
    const fixedX: number = isMinEdge ? b.maxX - padding * 0.5 : b.minX + padding * 0.5;
    const fixedY: number = isMinEdge ? b.maxY - padding * 0.5 : b.minY + padding * 0.5;
    const nextPoints: Point[] = s.points.map((p: Point): Point => ({
      x: isX ? fixedX + (p.x - fixedX) * scale : p.x,
      y: !isX ? fixedY + (p.y - fixedY) * scale : p.y,
    }));
    if (s.type === ShapeType.PATH) {
      const err: string = checkPathZeroLengthCollapse(s.points, nextPoints);
      if (err.length > 0) return err;
    }
    s.points = nextPoints;
    return '';
  }

  if (key === 'x' || key === 'y' || key === 'width' || key === 'height') {
    const b = getShapeBounds(s);
    const w: number = b.maxX - b.minX; const h: number = b.maxY - b.minY;
    if (key === 'width' || key === 'height') {
      if (s.type === ShapeType.TEXT || s.type === ShapeType.INSTANCE || n <= 0 ||
        (key === 'width' ? w : h) <= 0) return '宽高必须大于 0，且对象需要可缩放的几何';
    }
    const padding: number = shapePathPadding(s);
    const extent: number = (key === 'width' ? w : h) - padding;
    if ((key === 'width' || key === 'height') && (n < padding || (extent === 0 && n !== padding))) {
      return '该尺寸小于线宽/延伸，或路径在此方向没有跨度；请调整线宽或顶点';
    }
    const scale: number = extent === 0 ? 1 : (n - padding) / extent;
    const sx: number = key === 'width' ? scale : 1;
    const sy: number = key === 'height' ? scale : 1;
    const dx: number = key === 'x' ? n - b.minX : 0; const dy: number = key === 'y' ? n - b.minY : 0;
    const nextPoints: Point[] = s.points.map((p: Point): Point => {
      const next: Point = { x: b.minX + padding / 2 + (p.x - b.minX - padding / 2) * sx + dx,
        y: b.minY + padding / 2 + (p.y - b.minY - padding / 2) * sy + dy };
      return next;
    });
    if (s.type === ShapeType.PATH) {
      const err: string = checkPathZeroLengthCollapse(s.points, nextPoints);
      if (err.length > 0) return err;
    }
    s.points = nextPoints;
    return '';
  }
  if (key.indexOf('path') === 0) {
    if (s.type !== ShapeType.PATH) return '路径属性仅适用于 PATH';
    switch (key) {
      case 'pathWidth': if (n <= 0) return '线宽必须大于 0'; s.pathWidth = n; break;
      case 'pathType': if ([0, 1, 2, 4].indexOf(n) < 0) return '端型：0 平端、1 圆端、2 方延伸、4 自定义'; s.pathType = n; break;
      case 'pathBeginExtension': s.pathType = 4; s.pathBeginExtension = n; break;
      case 'pathEndExtension': s.pathType = 4; s.pathEndExtension = n; break;
      case 'pathWidthAbsolute': if (n !== 0 && n !== 1) return '固定线宽填 0 或 1'; s.pathWidthAbsolute = n === 1; break;
      default: return '不支持此路径属性';
    }
    return '';
  }
  if (s.type === ShapeType.TEXT) {
    if (key === 'rotation') { s.rotation = ((n % 360) + 360) % 360; return ''; }
    if (key === 'mirror') { if ([0, 1, 2].indexOf(n) < 0) return '镜像：0 无、1 X 轴、2 Y 轴'; s.mirror = n; return ''; }
    if (key === 'magnification') { if (n <= 0) return '倍率必须大于 0'; s.magnification = n; return ''; }
  }
  if (s.type !== ShapeType.INSTANCE) return '此属性仅适用于实例';
  switch (key) {
    case 'cellId': {
      const cell: PropertyCellOption | undefined = cells.find((c: PropertyCellOption) => c.id === n);
      if (cell === undefined) return '引用 Cell 不存在';
      const owner: number = s.ownerCellId ?? topCellId;
      const pending: number[] = [n]; const visited: Set<number> = new Set<number>();
      while (pending.length > 0) {
        const current: number = pending.pop() as number;
        if (current === owner) return '该引用会形成循环 Cell 层级';
        if (visited.has(current)) continue;
        visited.add(current);
        for (let i = 0; i < allShapes.length; i++) {
          const child: Shape = allShapes[i];
          if (child.type === ShapeType.INSTANCE && (child.ownerCellId ?? topCellId) === current && child.cellId !== undefined) pending.push(child.cellId);
        }
      }
      s.cellId = cell.id; s.cellName = cell.name; break;
    }
    case 'rotation': s.rotation = ((n % 360) + 360) % 360; break;
    case 'mirror': if ([0, 1, 2].indexOf(n) < 0) return '镜像：0 无、1 X 轴、2 Y 轴'; s.mirror = n; break;
    case 'magnification': if (n <= 0) return '倍率必须大于 0'; s.magnification = n; break;
    case 'arrayCols': if (!Number.isInteger(n) || n < 1 || n > 32767) return '列数须为 1–32767 整数'; s.arrayCols = n; break;
    case 'arrayRows': if (!Number.isInteger(n) || n < 1 || n > 32767) return '行数须为 1–32767 整数'; s.arrayRows = n; break;
    case 'arrayColStepX': s.arrayColStepX = n; break;
    case 'arrayColStepY': s.arrayColStepY = n; break;
    case 'arrayRowStepX': s.arrayRowStepX = n; break;
    case 'arrayRowStepY': s.arrayRowStepY = n; break;
    default: return '不支持此属性';
  }
  return '';
}

function utf8Length(text: string): number {
  let bytes: number = 0;
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 128) bytes++;
    else if (code < 2048) bytes += 2;
    else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length &&
      text.charCodeAt(i + 1) >= 0xDC00 && text.charCodeAt(i + 1) <= 0xDFFF) { bytes += 4; i++; }
    else bytes += 3;
  }
  return bytes;
}

interface PropertyReferenceBudget { parent: number; copies: number; }

/** Native/workspace budget convention: maximum expanded count of any Cell, never a sum of parent and child. */
export function validatePropertyHierarchy(shapes: Shape[], topCellId: number, cellCount?: number): string {
  if (!Number.isInteger(topCellId) || topCellId < 0 || (cellCount !== undefined && topCellId >= cellCount)) {
    return '顶层 Cell 标识无效';
  }
  const ids: Set<number> = new Set<number>([topCellId]);
  if (cellCount !== undefined) {
    for (let c = 0; c < cellCount; c++) {
      ids.add(c);
    }
  }
  for (const shape of shapes) {
    const owner: number = shape.ownerCellId ?? topCellId;
    if (!Number.isInteger(owner) || owner < 0 || (cellCount !== undefined && owner >= cellCount)) {
      return '图形归属 Cell 无效';
    }
    ids.add(owner);
    if (shape.type === ShapeType.INSTANCE) {
      if (shape.cellId === undefined || !Number.isInteger(shape.cellId) || shape.cellId < 0 ||
        (cellCount !== undefined && shape.cellId >= cellCount)) {
        return '实例引用 Cell 无效';
      }
      ids.add(shape.cellId);
    }
  }
  const sizes: Map<number, number> = new Map<number, number>();
  const depths: Map<number, number> = new Map<number, number>();
  const pending: Map<number, number> = new Map<number, number>();
  const parents: Map<number, PropertyReferenceBudget[]> = new Map<number, PropertyReferenceBudget[]>();
  for (const id of ids) { sizes.set(id, 0); depths.set(id, 0); pending.set(id, 0); }
  for (const shape of shapes) {
    const owner: number = shape.ownerCellId ?? topCellId;
    if (shape.type !== ShapeType.INSTANCE || shape.cellId === undefined) { sizes.set(owner, (sizes.get(owner) ?? 0) + 1); continue; }
    pending.set(owner, (pending.get(owner) ?? 0) + 1);
    let list: PropertyReferenceBudget[] | undefined = parents.get(shape.cellId);
    if (list === undefined) { list = []; parents.set(shape.cellId, list); }
    list.push({ parent: owner, copies: (shape.arrayCols || 1) * (shape.arrayRows || 1) });
  }
  const ready: number[] = [];
  for (const id of ids) if (pending.get(id) === 0) ready.push(id);
  for (let cursor = 0; cursor < ready.length; cursor++) {
    const child: number = ready[cursor]; const count: number = sizes.get(child) ?? 0;
    if (count > 1000000) return '修改会使 Cell 实例/阵列展开超过 100 万预算，请减小阵列或拆分 Cell';
    if ((depths.get(child) ?? 0) > 256) return '修改会使层级超过 256 层';
    for (const ref of parents.get(child) ?? []) {
      sizes.set(ref.parent, (sizes.get(ref.parent) ?? 0) + ref.copies * Math.max(1, count));
      depths.set(ref.parent, Math.max(depths.get(ref.parent) ?? 0, (depths.get(child) ?? 0) + 1));
      const left: number = (pending.get(ref.parent) ?? 0) - 1; pending.set(ref.parent, left);
      if (left === 0) ready.push(ref.parent);
    }
  }
  return ready.length === ids.size ? '' : '修改会形成循环 Cell 引用';
}
