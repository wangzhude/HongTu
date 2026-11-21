import { COLORS, worldToScreenPx, worldToScreenYpx } from '../../common/constants';
import { RADIUS, withAlpha } from '../../common/MaterialTokens';
import { Shape, ShapeType, Point, ShapeBounds, getShapeBounds, normalizePropRecords } from '../../models/GdsiiData';
import { AiCellInfo, AiContext, AiCommandType, CommandParams, ParsedCommand } from '../../services/AiService';
import { PropertyCellOption, prepareShapeProperty } from '../../services/ShapePropertyService';

interface PreviewGeometry {
  shape: Shape;
  original: Shape;
  created: boolean;
  aggregate: boolean;
  changed: boolean;
  deleted: boolean;
  supported: boolean;
  focused: boolean;
}

export interface AiPreviewBox {
  key: string;
  bounds: ShapeBounds;
  label: string;
  deleted: boolean;
  anchor: boolean;
  beforeBounds?: ShapeBounds;
  shapeId?: number;
  shapeType?: ShapeType;
  points?: Point[];
  beforePoints?: Point[];
  pathWidth?: number;
  beforePathWidth?: number;
  layerNumber?: number;
  datatype?: number;
  beforeLayerNumber?: number;
  beforeDatatype?: number;
  created?: boolean;
  focusedOnly?: boolean;
}

export interface AiPreviewResult {
  boxes: AiPreviewBox[];
  note: string;
}

function copyPoints(points: Point[]): Point[] {
  return points.map((point: Point): Point => ({ x: point.x, y: point.y }));
}

/** Preview objects own their points. Neither the source shapes nor editing services are mutated. */
function copyShape(shape: Shape): Shape {
  return {
    id: shape.id,
    type: shape.type,
    layerNumber: shape.layerNumber,
    datatype: shape.datatype,
    selected: false,
    points: copyPoints(shape.points),
    pathWidth: shape.pathWidth,
    pathType: shape.pathType,
    pathBeginExtension: shape.pathBeginExtension,
    pathEndExtension: shape.pathEndExtension,
    pathWidthAbsolute: shape.pathWidthAbsolute,
    text: shape.text,
    textPresentation: shape.textPresentation,
    ownerCellId: shape.ownerCellId,
    cellId: shape.cellId,
    cellName: shape.cellName,
    rotation: shape.rotation,
    mirror: shape.mirror,
    magnification: shape.magnification,
    arrayCols: shape.arrayCols,
    arrayRows: shape.arrayRows,
    arrayColStepX: shape.arrayColStepX,
    arrayColStepY: shape.arrayColStepY,
    arrayRowStepX: shape.arrayRowStepX,
    arrayRowStepY: shape.arrayRowStepY,
    properties: normalizePropRecords(shape.properties),
  };
}

function finitePoints(points: Point[]): boolean {
  return points.every((point: Point): boolean => Number.isFinite(point.x) && Number.isFinite(point.y));
}

function validGdsPair(layer: number | undefined, datatype: number | undefined): boolean {
  return layer !== undefined && datatype !== undefined &&
    Number.isInteger(layer) && layer >= 0 && layer <= 32767 &&
    Number.isInteger(datatype) && datatype >= 0 && datatype <= 32767;
}

/**
 * Pure command projection supporting both direct editor commands and native tools
 * (including single-axis rectangle width/height edits, path wire-width edits, and layer changes).
 */
class AiPreviewProjection {
  private source: Shape[];
  private items: PreviewGeometry[] = [];
  private selected: number[];
  private selectionKnown: boolean = true;
  private nextId: number = -1000000000;
  private omitted: boolean = false;
  private context: AiContext;

  constructor(shapes: Shape[], selectedIds: number[], context: AiContext) {
    this.source = shapes;
    this.selected = selectedIds.slice();
    this.context = context;
  }

  private cellOptions(): PropertyCellOption[] {
    return (this.context.cells ?? []).map((cell: AiCellInfo): PropertyCellOption => ({
      id: cell.id,
      name: cell.name
    }));
  }

  private find(id: number): PreviewGeometry | undefined {
    const existing: PreviewGeometry | undefined = this.items.find((item: PreviewGeometry): boolean => item.shape.id === id);
    if (existing !== undefined) {
      return existing.deleted ? undefined : existing;
    }
    const source: Shape | undefined = this.source.find((shape: Shape): boolean => shape.id === id);
    if (source === undefined || source.points.length === 0 || !finitePoints(source.points)) {
      return undefined;
    }
    const item: PreviewGeometry = {
      shape: copyShape(source),
      original: copyShape(source),
      created: false,
      aggregate: false,
      changed: false,
      deleted: false,
      supported: true,
      focused: false,
    };
    this.items.push(item);
    return item;
  }

  private add(type: ShapeType, layer: number, datatype: number, points: Point[], width: number = 0,
    text: string = '', aggregate: boolean = false): void {
    const shape: Shape = {
      id: this.nextId--,
      type: type,
      layerNumber: layer,
      datatype: datatype,
      ownerCellId: this.context.currentCell?.id,
      selected: false,
      points: copyPoints(points),
      pathWidth: width,
      text: text,
    };
    this.items.push({
      shape: shape,
      original: copyShape(shape),
      created: true,
      aggregate: aggregate,
      changed: true,
      deleted: false,
      supported: true,
      focused: false,
    });
    this.selected = [shape.id];
    this.selectionKnown = true;
  }

  private create(command: ParsedCommand): boolean {
    const p: CommandParams = command.params;
    if (command.type === AiCommandType.CREATE_ARRAY && p.width === undefined && p.height === undefined) {
      if (p.shapeIds !== undefined && !this.selectIds(command)) return false;
      if (!this.selectionKnown || this.selected.length === 0 || !Number.isInteger(p.rows) || !Number.isInteger(p.cols) ||
        p.rows! < 1 || p.cols! < 1 || p.rows! * p.cols! > 10000 || !Number.isFinite(p.spacingX) || !Number.isFinite(p.spacingY)) return false;
      const ids: number[] = this.selected.slice();
      for (const id of ids) {
        const item: PreviewGeometry | undefined = this.find(id);
        if (item === undefined) return false;
        const box: ShapeBounds = getShapeBounds(item.shape);
        const dx: number = (p.cols! - 1) * p.spacingX!;
        const dy: number = (p.rows! - 1) * p.spacingY!;
        this.add(ShapeType.RECT, item.shape.layerNumber, item.shape.datatype,
          [{ x: box.minX + Math.min(0, dx), y: box.minY + Math.min(0, dy) },
           { x: box.maxX + Math.max(0, dx), y: box.maxY + Math.max(0, dy) }], 0, '', true);
      }
      this.selectionKnown = false;
      return true;
    }
    const layer = p.layer ?? this.context.currentLayer;
    const datatype = p.datatype ?? (layer === this.context.currentLayer ? (this.context.currentDatatype ?? 0) : 0);
    if (!validGdsPair(layer, datatype)) {
      return false;
    }
    const x: number = p.x ?? 0;
    const y: number = p.y ?? 0;
    if (!Number.isFinite(x) || !Number.isFinite(y)) {
      return false;
    }
    if (command.type === AiCommandType.CREATE_RECT || command.type === AiCommandType.CREATE_ARRAY) {
      if (p.width === undefined || p.height === undefined || !Number.isFinite(p.width) ||
        !Number.isFinite(p.height) || p.width <= 0 || p.height <= 0) {
        return false;
      }
      if (command.type === AiCommandType.CREATE_RECT) {
        this.add(ShapeType.RECT, layer, datatype, [{ x: x, y: y }, { x: x + p.width, y: y + p.height }]);
        return true;
      }
      if (p.rows === undefined || p.cols === undefined || !Number.isInteger(p.rows) ||
        !Number.isInteger(p.cols) || p.rows < 1 || p.cols < 1 || p.rows > 1000 || p.cols > 1000) {
        return false;
      }
      const sx: number = p.spacingX ?? p.width;
      const sy: number = p.spacingY ?? p.height;
      if (!Number.isFinite(sx) || !Number.isFinite(sy)) {
        return false;
      }
      const endX: number = x + (p.cols - 1) * sx;
      const endY: number = y + (p.rows - 1) * sy;
      this.add(ShapeType.RECT, layer, datatype, [
        { x: Math.min(x, endX), y: Math.min(y, endY) },
        { x: Math.max(x, endX) + p.width, y: Math.max(y, endY) + p.height },
      ], 0, '', true);
      return true;
    }
    if (command.type === AiCommandType.CREATE_POLYGON || command.type === AiCommandType.CREATE_PATH) {
      const minimum: number = command.type === AiCommandType.CREATE_POLYGON ? 3 : 2;
      if (p.points === undefined || p.points.length < minimum || !finitePoints(p.points)) {
        return false;
      }
      const width: number = p.width ?? 4;
      if (command.type === AiCommandType.CREATE_PATH && (!Number.isFinite(width) || width < 0)) {
        return false;
      }
      this.add(command.type === AiCommandType.CREATE_POLYGON ? ShapeType.POLYGON : ShapeType.PATH,
        layer, datatype, p.points, width);
      return true;
    }
    if (command.type === AiCommandType.CREATE_TEXT && p.x !== undefined && p.y !== undefined &&
      p.text !== undefined && p.text.length > 0) {
      this.add(ShapeType.TEXT, layer, datatype, [{ x: x, y: y }], 0, p.text);
      return true;
    }
    return false;
  }

  private selectExplicitIds(ids: number[] | undefined, markFocus: boolean): boolean {
    const currentCell = this.context.currentCell;
    if (!Array.isArray(ids) || ids.length === 0 || ids.length > 512 ||
      ids.some((id: number) => !Number.isInteger(id) || id < 0)) return false;
    for (const id of ids) {
      const shape = this.source.find((candidate: Shape) => candidate.id === id);
      if (shape === undefined || shape.type === ShapeType.NODE) return false;
      if (currentCell !== undefined && (shape.ownerCellId ?? this.context.topCellId ?? 0) !== currentCell.id) return false;
      if (!this.find(id)) return false;
    }
    this.selected = Array.from(new Set<number>(ids));
    this.selectionKnown = true;
    if (markFocus) {
      for (const id of this.selected) {
        const item = this.find(id);
        if (item !== undefined) item.focused = true;
      }
    }
    return true;
  }

  private selectIds(command: ParsedCommand): boolean {
    return this.selectExplicitIds(command.params.shapeIds, command.params.focus !== false);
  }

  private applyPropertyToTarget(item: PreviewGeometry, property: string, value: string): boolean {
    if (item.aggregate) {
      item.supported = false;
      return false;
    }
    const clone: Shape = copyShape(item.shape);
    const error: string = prepareShapeProperty(clone, property, value, this.cellOptions(), this.source, this.context.topCellId ?? 0);
    if (error.length > 0) {
      return false;
    }
    item.shape = clone;
    item.changed = true;
    return true;
  }

  private applyDimensionOrLayerParams(item: PreviewGeometry, p: CommandParams): boolean {
    let applied: boolean = false;
    if (p.layer !== undefined) {
      const nextDatatype: number = p.datatype ?? item.shape.datatype;
      if (!validGdsPair(p.layer, nextDatatype) || item.shape.type === ShapeType.INSTANCE) {
        return false;
      }
      item.shape.layerNumber = p.layer;
      item.shape.datatype = nextDatatype;
      item.changed = true;
      applied = true;
    }
    if (p.x !== undefined && Number.isFinite(p.x)) {
      if (!this.applyPropertyToTarget(item, 'x', `${p.x}`)) return false;
      applied = true;
    }
    if (p.y !== undefined && Number.isFinite(p.y)) {
      if (!this.applyPropertyToTarget(item, 'y', `${p.y}`)) return false;
      applied = true;
    }
    if (p.width !== undefined) {
      if (!Number.isFinite(p.width) || p.width <= 0) return false;
      if (item.shape.type === ShapeType.PATH && p.height === undefined) {
        if (!this.applyPropertyToTarget(item, 'pathWidth', `${p.width}`)) return false;
      } else {
        if (!this.applyPropertyToTarget(item, 'width', `${p.width}`)) return false;
      }
      applied = true;
    }
    if (p.height !== undefined) {
      if (!Number.isFinite(p.height) || p.height <= 0) return false;
      if (!this.applyPropertyToTarget(item, 'height', `${p.height}`)) return false;
      applied = true;
    }
    return applied;
  }

  private transform(command: ParsedCommand): void {
    if (command.params.shapeIds !== undefined && !this.selectExplicitIds(command.params.shapeIds, false)) {
      this.omitted = true;
      return;
    }
    if (!this.selectionKnown || this.selected.length === 0) {
      this.omitted = true;
      return;
    }
    const p: CommandParams = command.params;
    for (let i: number = 0; i < this.selected.length; i++) {
      const item: PreviewGeometry | undefined = this.find(this.selected[i]);
      if (item === undefined) {
        this.omitted = true;
        continue;
      }
      if (command.type === AiCommandType.DELETE_SHAPE) {
        item.deleted = true;
        item.changed = true;
        item.shape = copyShape(item.original);
        continue;
      }
      if (command.type === AiCommandType.MOVE_SHAPE) {
        const hasOffset: boolean = p.dx !== undefined || p.dy !== undefined;
        if (hasOffset) {
          const dx: number = p.dx ?? 0;
          const dy: number = p.dy ?? 0;
          if (!Number.isFinite(dx) || !Number.isFinite(dy)) {
            this.omitted = true;
            continue;
          }
          item.shape.points = item.shape.points.map((point: Point): Point => ({ x: point.x + dx, y: point.y + dy }));
          item.changed = true;
        }
        if (p.layer !== undefined || p.width !== undefined || p.height !== undefined || p.x !== undefined || p.y !== undefined) {
          if (!this.applyDimensionOrLayerParams(item, p)) {
            this.omitted = true;
          }
        } else if (!hasOffset) {
          this.omitted = true;
        }
        continue;
      }
      if (command.type === AiCommandType.SCALE_SHAPE && p.scale === undefined &&
        (p.width !== undefined || p.height !== undefined || p.layer !== undefined || p.x !== undefined || p.y !== undefined)) {
        if (!this.applyDimensionOrLayerParams(item, p)) {
          this.omitted = true;
        }
        continue;
      }
      if (item.shape.type === ShapeType.INSTANCE || item.aggregate) {
        item.supported = false;
        this.omitted = true;
        continue;
      }
      let minX: number = Infinity;
      let minY: number = Infinity;
      let maxX: number = -Infinity;
      let maxY: number = -Infinity;
      for (const point of item.shape.points) {
        minX = Math.min(minX, point.x);
        minY = Math.min(minY, point.y);
        maxX = Math.max(maxX, point.x);
        maxY = Math.max(maxY, point.y);
      }
      const cx: number = p.centerX !== undefined && Number.isFinite(p.centerX) ? p.centerX : (minX + maxX) / 2;
      const cy: number = p.centerY !== undefined && Number.isFinite(p.centerY) ? p.centerY : (minY + maxY) / 2;
      if (command.type === AiCommandType.ROTATE_SHAPE && p.degrees !== undefined && Number.isFinite(p.degrees)) {
        const angle: number = p.degrees * Math.PI / 180;
        item.shape.points = item.shape.points.map((point: Point): Point => ({
          x: Math.round(cx + (point.x - cx) * Math.cos(angle) - (point.y - cy) * Math.sin(angle)),
          y: Math.round(cy + (point.x - cx) * Math.sin(angle) + (point.y - cy) * Math.cos(angle)),
        }));
      } else if (command.type === AiCommandType.MIRROR_SHAPE && p.horizontal !== undefined) {
        item.shape.points = item.shape.points.map((point: Point): Point => ({
          x: p.horizontal === 1 ? point.x : 2 * cx - point.x,
          y: p.horizontal === 1 ? 2 * cy - point.y : point.y,
        }));
      } else if (command.type === AiCommandType.SCALE_SHAPE && p.scale !== undefined &&
        Number.isFinite(p.scale) && p.scale > 0) {
        const factor: number = p.scale;
        item.shape.points = item.shape.points.map((point: Point): Point => ({
          x: cx + (point.x - cx) * factor,
          y: cy + (point.y - cy) * factor,
        }));
        if (item.shape.type === ShapeType.PATH && item.shape.pathWidth !== undefined) {
          item.shape.pathWidth *= factor;
          if (item.shape.pathBeginExtension !== undefined) item.shape.pathBeginExtension *= factor;
          if (item.shape.pathEndExtension !== undefined) item.shape.pathEndExtension *= factor;
        }
      } else {
        this.omitted = true;
        continue;
      }
      if (p.layer !== undefined && !this.applyDimensionOrLayerParams(item, { layer: p.layer, datatype: p.datatype })) {
        this.omitted = true;
        continue;
      }
      item.changed = true;
    }
    if (command.type === AiCommandType.DELETE_SHAPE) {
      this.selected = [];
    }
  }

  private projectNativeTool(command: ParsedCommand): void {
    const toolName: string = command.params.nativeTool ?? '';
    const rawJson: string = command.params.argumentsJson ?? '';
    if (toolName.length === 0 || rawJson.length === 0) {
      this.omitted = true;
      return;
    }
    let args: Record<string, Object>;
    try {
      const parsed: Object = JSON.parse(rawJson) as Object;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        this.omitted = true;
        return;
      }
      args = parsed as Record<string, Object>;
    } catch (_) {
      this.omitted = true;
      return;
    }

    if (toolName.startsWith('editor.')) {
      const subType: AiCommandType = toolName.substring(7) as AiCommandType;
      const mappedParams: CommandParams = args as Object as CommandParams;
      const subCommand: ParsedCommand = {
        type: subType,
        params: mappedParams,
        description: command.description
      };
      if (subType === AiCommandType.CREATE_RECT || subType === AiCommandType.CREATE_POLYGON ||
        subType === AiCommandType.CREATE_PATH || subType === AiCommandType.CREATE_TEXT ||
        subType === AiCommandType.CREATE_ARRAY) {
        if (!this.create(subCommand)) this.omitted = true;
      } else {
        this.transform(subCommand);
      }
      return;
    }

    if (toolName === 'selection.set') {
      const ids: number[] | undefined = Array.isArray(args['shapeIds']) ? (args['shapeIds'] as number[]) : undefined;
      if (ids !== undefined && ids.length === 0) {
        this.selected = [];
        this.selectionKnown = true;
      } else if (!this.selectExplicitIds(ids, true)) {
        this.selectionKnown = false;
        this.omitted = true;
      }
      return;
    }

    if (toolName === 'selection.layer') {
      const ids: number[] | undefined = Array.isArray(args['shapeIds']) ? (args['shapeIds'] as number[]) : undefined;
      const layer: number | undefined = typeof args['layer'] === 'number' ? (args['layer'] as number) : undefined;
      const datatype: number | undefined = typeof args['datatype'] === 'number' ? (args['datatype'] as number) : undefined;
      if (!this.selectExplicitIds(ids, false) || !validGdsPair(layer, datatype)) {
        this.omitted = true;
        return;
      }
      for (const id of this.selected) {
        const item: PreviewGeometry | undefined = this.find(id);
        if (item === undefined || item.shape.type === ShapeType.INSTANCE) {
          this.omitted = true;
          continue;
        }
        item.shape.layerNumber = layer!;
        item.shape.datatype = datatype!;
        item.changed = true;
      }
      return;
    }

    if (toolName === 'selection.property') {
      const ids: number[] | undefined = Array.isArray(args['shapeIds']) ? (args['shapeIds'] as number[]) : undefined;
      const property: string = typeof args['property'] === 'string' ? (args['property'] as string) : '';
      const value: string = typeof args['value'] === 'string' ? (args['value'] as string) :
        (typeof args['value'] === 'number' ? `${args['value'] as number}` : '');
      if (!this.selectExplicitIds(ids, false) || property.length === 0) {
        this.omitted = true;
        return;
      }
      for (const id of this.selected) {
        const item: PreviewGeometry | undefined = this.find(id);
        if (item === undefined || !this.applyPropertyToTarget(item, property, value)) {
          this.omitted = true;
        }
      }
      return;
    }

    if (toolName === 'selection.offset') {
      const ids: number[] | undefined = Array.isArray(args['shapeIds']) ? (args['shapeIds'] as number[]) : undefined;
      const offsetNm: number = typeof args['offsetNm'] === 'number' ? (args['offsetNm'] as number) : NaN;
      if (!this.selectExplicitIds(ids, false) || !Number.isFinite(offsetNm)) {
        this.omitted = true;
        return;
      }
      for (const id of this.selected) {
        const item: PreviewGeometry | undefined = this.find(id);
        if (item === undefined || item.shape.type !== ShapeType.RECT) {
          this.omitted = true;
          continue;
        }
        const b: ShapeBounds = getShapeBounds(item.shape);
        const nextMinX: number = b.minX - offsetNm;
        const nextMinY: number = b.minY - offsetNm;
        const nextMaxX: number = b.maxX + offsetNm;
        const nextMaxY: number = b.maxY + offsetNm;
        if (nextMaxX <= nextMinX || nextMaxY <= nextMinY) {
          this.omitted = true;
          continue;
        }
        item.shape.points = [{ x: nextMinX, y: nextMinY }, { x: nextMaxX, y: nextMaxY }];
        item.changed = true;
      }
      return;
    }

    if (toolName === 'vertex.move' || toolName === 'vertex.insert' || toolName === 'vertex.delete') {
      const shapeId: number = typeof args['shapeId'] === 'number' ? (args['shapeId'] as number) : -1;
      const index: number = typeof args['index'] === 'number' ? (args['index'] as number) : -1;
      if (!this.selectExplicitIds([shapeId], false) || !Number.isInteger(index) || index < 0) {
        this.omitted = true;
        return;
      }
      const item: PreviewGeometry | undefined = this.find(shapeId);
      if (item === undefined || item.shape.type === ShapeType.RECT || item.shape.type === ShapeType.INSTANCE || item.shape.type === ShapeType.TEXT) {
        this.omitted = true;
        return;
      }
      const pts: Point[] = copyPoints(item.shape.points);
      if (toolName === 'vertex.move') {
        const x: number = typeof args['x'] === 'number' ? (args['x'] as number) : NaN;
        const y: number = typeof args['y'] === 'number' ? (args['y'] as number) : NaN;
        if (index >= pts.length || !Number.isFinite(x) || !Number.isFinite(y)) { this.omitted = true; return; }
        pts[index] = { x: x, y: y };
      } else if (toolName === 'vertex.insert') {
        const x: number = typeof args['x'] === 'number' ? (args['x'] as number) : NaN;
        const y: number = typeof args['y'] === 'number' ? (args['y'] as number) : NaN;
        if (index > pts.length || !Number.isFinite(x) || !Number.isFinite(y)) { this.omitted = true; return; }
        pts.splice(index, 0, { x: x, y: y });
      } else {
        const minPts: number = item.shape.type === ShapeType.POLYGON ? 3 : 2;
        if (index >= pts.length || pts.length <= minPts) { this.omitted = true; return; }
        pts.splice(index, 1);
      }
      item.shape.points = pts;
      item.changed = true;
      return;
    }

    if (toolName === 'layers.select' || toolName === 'layers.visible' || toolName === 'view.fit' || toolName === 'view.zoom') {
      return;
    }
    this.omitted = true;
  }

  project(commands: ParsedCommand[]): AiPreviewResult {
    for (let i: number = 0; i < commands.length; i++) {
      const command: ParsedCommand = commands[i];
      if (command.type === AiCommandType.NATIVE_TOOL) {
        this.projectNativeTool(command);
      } else if (command.type === AiCommandType.CREATE_RECT || command.type === AiCommandType.CREATE_POLYGON ||
        command.type === AiCommandType.CREATE_PATH || command.type === AiCommandType.CREATE_TEXT ||
        command.type === AiCommandType.CREATE_ARRAY) {
        if (!this.create(command)) {
          this.omitted = true;
        }
      } else if (command.type === AiCommandType.MOVE_SHAPE || command.type === AiCommandType.DELETE_SHAPE ||
        command.type === AiCommandType.ROTATE_SHAPE || command.type === AiCommandType.MIRROR_SHAPE ||
        command.type === AiCommandType.SCALE_SHAPE) {
        this.transform(command);
      } else if (command.type === AiCommandType.SELECT_LAYER && command.params.shapeIds !== undefined && command.params.layer !== undefined) {
        if (!this.selectExplicitIds(command.params.shapeIds, false)) {
          this.omitted = true;
        } else {
          for (const id of this.selected) {
            const item: PreviewGeometry | undefined = this.find(id);
            if (item === undefined || !this.applyDimensionOrLayerParams(item, command.params)) {
              this.omitted = true;
            }
          }
        }
      } else if (command.type === AiCommandType.SELECT_SHAPE && command.params.shapeIds !== undefined) {
        if (!this.selectIds(command)) {
          this.selectionKnown = false;
          this.omitted = true;
        }
      } else if (command.type === AiCommandType.SELECT_SHAPE || command.type === AiCommandType.BATCH_OPERATION) {
        this.selectionKnown = false;
        this.omitted = true;
      }
    }
    const boxes: AiPreviewBox[] = [];
    for (let i: number = 0; i < this.items.length; i++) {
      const item: PreviewGeometry = this.items[i];
      if ((!item.changed && !item.focused) || !item.supported || (item.created && item.deleted) || !finitePoints(item.shape.points)) {
        continue;
      }
      const anchor: boolean = item.shape.type === ShapeType.TEXT || item.shape.type === ShapeType.INSTANCE;
      const focusedOnly: boolean = !item.changed && item.focused;
      boxes.push({
        key: `${item.shape.id}`,
        bounds: getShapeBounds(item.shape),
        label: '预览 · 未应用',
        deleted: item.deleted,
        anchor: anchor,
        beforeBounds: item.created ? undefined : getShapeBounds(item.original),
        shapeId: item.created ? undefined : item.shape.id,
        shapeType: item.shape.type,
        points: copyPoints(item.shape.points),
        beforePoints: item.created ? undefined : copyPoints(item.original.points),
        pathWidth: item.shape.pathWidth,
        beforePathWidth: item.created ? undefined : item.original.pathWidth,
        layerNumber: item.shape.layerNumber,
        datatype: item.shape.datatype,
        beforeLayerNumber: item.created ? undefined : item.original.layerNumber,
        beforeDatatype: item.created ? undefined : item.original.datatype,
        created: item.created,
        focusedOnly: focusedOnly,
      });
    }
    return { boxes: boxes, note: this.omitted ? '部分指令无法确定几何范围，请核对修改卡片' : '' };
  }
}

export function buildAiCommandPreview(commands: ParsedCommand[], context: AiContext | null,
  shapes: Shape[], selectedIds: number[]): AiPreviewResult {
  if (commands.length === 0) {
    return { boxes: [], note: '' };
  }
  if (context === null) {
    return { boxes: [], note: '待应用指令缺少上下文，未绘制几何预览' };
  }
  return new AiPreviewProjection(shapes, selectedIds, context).project(commands);
}

@Component
export struct AiCommandPreview {
  @Prop @Watch('refreshPreview') commands: ParsedCommand[] = [];
  @Prop @Watch('refreshPreview') context: AiContext | null = null;
  @Link @Watch('refreshPreview') shapes: Shape[];
  @Prop @Watch('refreshPreview') selectedIds: number[] = [];
  @Prop @Watch('redrawCanvas') zoomPercent: number = 100;
  @Prop @Watch('redrawCanvas') viewOffsetX: number = 0;
  @Prop @Watch('redrawCanvas') viewOffsetY: number = 0;
  @State boxes: AiPreviewBox[] = [];
  @State note: string = '';

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasReady: boolean = false;
  private canvasWidthVp: number = 0;
  private canvasHeightVp: number = 0;

  aboutToAppear(): void {
    this.refreshPreview();
  }

  refreshPreview(): void {
    const preview: AiPreviewResult = buildAiCommandPreview(this.commands, this.context, this.shapes, this.selectedIds);
    this.boxes = preview.boxes;
    this.note = preview.note;
    this.redrawCanvas();
  }

  private sx(worldX: number): number {
    return worldToScreenPx(worldX, this.zoomPercent, this.viewOffsetX);
  }

  private sy(worldY: number): number {
    return worldToScreenYpx(worldY, this.zoomPercent, this.viewOffsetY);
  }

  private left(box: AiPreviewBox): number {
    return this.sx(box.bounds.minX) - (box.anchor ? 6 : 0);
  }

  private top(box: AiPreviewBox): number {
    return this.sy(box.bounds.maxY) - (box.anchor ? 6 : 0);
  }

  private drawAnchor(cx: number, cy: number, color: string): void {
    this.ctx.save();
    this.ctx.strokeStyle = color;
    this.ctx.fillStyle = withAlpha(color, 0.12);
    this.ctx.lineWidth = 1.5;
    this.ctx.setLineDash([4, 3]);
    this.ctx.beginPath();
    this.ctx.arc(cx, cy, 7, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.stroke();
    this.ctx.setLineDash([]);
    this.ctx.beginPath();
    this.ctx.moveTo(cx - 10, cy);
    this.ctx.lineTo(cx + 10, cy);
    this.ctx.moveTo(cx, cy - 10);
    this.ctx.lineTo(cx, cy + 10);
    this.ctx.stroke();
    this.ctx.restore();
  }

  private drawRectDeltaAndContour(box: AiPreviewBox, strokeColor: string): void {
    const x1: number = this.sx(box.bounds.minX);
    const y1: number = this.sy(box.bounds.maxY);
    const w: number = Math.max(2, this.sx(box.bounds.maxX) - x1);
    const h: number = Math.max(2, this.sy(box.bounds.minY) - y1);

    this.ctx.save();
    if (box.beforeBounds !== undefined && !box.deleted) {
      const bx1: number = this.sx(box.beforeBounds.minX);
      const by1: number = this.sy(box.beforeBounds.maxY);
      const bw: number = Math.max(2, this.sx(box.beforeBounds.maxX) - bx1);
      const bh: number = Math.max(2, this.sy(box.beforeBounds.minY) - by1);
      const boundsChanged: boolean = Math.abs(bx1 - x1) > 0.5 || Math.abs(by1 - y1) > 0.5 ||
        Math.abs(bw - w) > 0.5 || Math.abs(bh - h) > 0.5;
      if (boundsChanged) {
        this.ctx.strokeStyle = withAlpha(strokeColor, 0.35);
        this.ctx.lineWidth = 1;
        this.ctx.setLineDash([3, 3]);
        this.ctx.strokeRect(bx1, by1, bw, bh);

        // Highlight single-axis width/height extension segments cleanly
        if (Math.abs(bx1 - x1) < 0.5 && Math.abs(by1 - y1) < 0.5 && Math.abs(bh - h) < 0.5 && w > bw + 0.5) {
          this.ctx.fillStyle = withAlpha(strokeColor, 0.10);
          this.ctx.fillRect(bx1 + bw, y1, w - bw, h);
        } else if (Math.abs(bx1 - x1) < 0.5 && Math.abs(bw - w) < 0.5 && h > bh + 0.5) {
          const extTop: number = Math.min(y1, by1);
          const extHeight: number = Math.abs(h - bh);
          this.ctx.fillStyle = withAlpha(strokeColor, 0.10);
          this.ctx.fillRect(x1, y1 < by1 ? extTop : by1 + bh, w, extHeight);
        } else {
          this.ctx.fillStyle = withAlpha(strokeColor, 0.06);
          this.ctx.fillRect(x1, y1, w, h);
        }
      } else {
        this.ctx.fillStyle = withAlpha(strokeColor, 0.06);
        this.ctx.fillRect(x1, y1, w, h);
      }
    } else {
      this.ctx.fillStyle = withAlpha(strokeColor, 0.07);
      this.ctx.fillRect(x1, y1, w, h);
    }

    this.ctx.strokeStyle = strokeColor;
    this.ctx.lineWidth = 1.75;
    this.ctx.setLineDash([6, 4]);
    this.ctx.strokeRect(x1, y1, w, h);

    if (box.deleted) {
      this.ctx.strokeStyle = withAlpha(strokeColor, 0.45);
      this.ctx.lineWidth = 1.2;
      this.ctx.setLineDash([4, 4]);
      this.ctx.beginPath();
      this.ctx.moveTo(x1, y1);
      this.ctx.lineTo(x1 + w, y1 + h);
      this.ctx.stroke();
    }
    this.ctx.restore();
  }

  private drawPolygonContour(box: AiPreviewBox, strokeColor: string): void {
    const pts: Point[] = box.points ?? [];
    if (pts.length < 3) {
      this.drawRectDeltaAndContour(box, strokeColor);
      return;
    }
    this.ctx.save();
    this.ctx.beginPath();
    this.ctx.moveTo(this.sx(pts[0].x), this.sy(pts[0].y));
    for (let i: number = 1; i < pts.length; i++) {
      this.ctx.lineTo(this.sx(pts[i].x), this.sy(pts[i].y));
    }
    this.ctx.closePath();
    this.ctx.fillStyle = withAlpha(strokeColor, 0.07);
    this.ctx.fill();
    this.ctx.strokeStyle = strokeColor;
    this.ctx.lineWidth = 1.75;
    this.ctx.lineJoin = 'round';
    this.ctx.setLineDash([6, 4]);
    this.ctx.stroke();
    this.ctx.restore();
  }

  private drawPathContour(box: AiPreviewBox, strokeColor: string): void {
    const pts: Point[] = box.points ?? [];
    if (pts.length < 2) {
      this.drawRectDeltaAndContour(box, strokeColor);
      return;
    }
    const widthNm: number = Math.max(0, box.pathWidth ?? 0);
    const widthPx: number = Math.max(2, Math.abs(this.sx(widthNm) - this.sx(0)));

    this.ctx.save();
    if (widthPx >= 4) {
      this.ctx.beginPath();
      this.ctx.moveTo(this.sx(pts[0].x), this.sy(pts[0].y));
      for (let i: number = 1; i < pts.length; i++) {
        this.ctx.lineTo(this.sx(pts[i].x), this.sy(pts[i].y));
      }
      this.ctx.strokeStyle = withAlpha(strokeColor, 0.14);
      this.ctx.lineWidth = widthPx;
      this.ctx.lineCap = 'butt';
      this.ctx.lineJoin = 'miter';
      this.ctx.setLineDash([]);
      this.ctx.stroke();
    }

    // Outer dashed bounding envelope for wire-width clarity
    const x1: number = this.sx(box.bounds.minX);
    const y1: number = this.sy(box.bounds.maxY);
    const w: number = Math.max(2, this.sx(box.bounds.maxX) - x1);
    const h: number = Math.max(2, this.sy(box.bounds.minY) - y1);
    this.ctx.strokeStyle = strokeColor;
    this.ctx.lineWidth = 1.6;
    this.ctx.setLineDash([6, 4]);
    if (pts.length === 2 && (pts[0].x === pts[1].x || pts[0].y === pts[1].y)) {
      this.ctx.strokeRect(x1, y1, w, h);
    } else {
      this.ctx.beginPath();
      this.ctx.moveTo(this.sx(pts[0].x), this.sy(pts[0].y));
      for (let i: number = 1; i < pts.length; i++) {
        this.ctx.lineTo(this.sx(pts[i].x), this.sy(pts[i].y));
      }
      this.ctx.stroke();
    }
    this.ctx.restore();
  }

  redrawCanvas(): void {
    if (!this.canvasReady) {
      return;
    }
    const w: number = Math.max(1, this.canvasWidthVp || this.ctx.width || 1);
    const h: number = Math.max(1, this.canvasHeightVp || this.ctx.height || 1);
    this.ctx.clearRect(0, 0, w, h);

    for (let i: number = 0; i < this.boxes.length; i++) {
      const box: AiPreviewBox = this.boxes[i];
      const strokeColor: string = box.deleted ? COLORS.danger : COLORS.primary;
      if (box.anchor) {
        this.drawAnchor(this.sx(box.bounds.minX), this.sy(box.bounds.maxY), strokeColor);
      } else if (box.shapeType === ShapeType.POLYGON) {
        this.drawPolygonContour(box, strokeColor);
      } else if (box.shapeType === ShapeType.PATH) {
        this.drawPathContour(box, strokeColor);
      } else {
        this.drawRectDeltaAndContour(box, strokeColor);
      }
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .onReady(() => {
          this.canvasReady = true;
          this.redrawCanvas();
        })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.canvasWidthVp = Number(newArea.width) || 0;
          this.canvasHeightVp = Number(newArea.height) || 0;
          this.redrawCanvas();
        })

      ForEach(this.boxes, (box: AiPreviewBox) => {
        Text(box.label)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(box.deleted ? COLORS.danger : COLORS.primary)
          .backgroundColor(COLORS.surface)
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .border({ width: 0.8, color: withAlpha(box.deleted ? COLORS.danger : COLORS.primary, 0.35) })
          .borderRadius(RADIUS.xs)
          .position({ x: Math.max(8, this.left(box)), y: Math.max(6, this.top(box) - 26) })
          .hitTestBehavior(HitTestMode.None)
      }, (box: AiPreviewBox) => box.key)

      if (this.note.length > 0) {
        Text(this.note)
          .fontSize(11)
          .fontColor(COLORS.muted)
          .backgroundColor(COLORS.surface)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .border({ width: 0.8, color: COLORS.border })
          .borderRadius(RADIUS.sm)
          .position({ x: 70, y: 10 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }
}
