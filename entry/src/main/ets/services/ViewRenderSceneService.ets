import { ShapeType, getShapeBounds, packShapesCoordinates } from '../models/GdsiiData';
import type { Shape, Point, ShapeBounds } from '../models/GdsiiData';
import type { ViewAffine } from '../models/ViewWorkspace';
import type { ViewSceneSource, ViewScenePrimitive, ViewSceneDrawResult, ViewSceneTextMetrics } from '../models/ViewRenderScene';
import type { NativeRenderSceneSource, NativeLayerRenderStyle } from '../../cpp/types/libhongtu/Index';
import { fillPatternForHatch, layerRenderStyle } from '../common/MaterialTokens';
import { instanceTransformMat, HierarchyReferenceBoundsResolver } from './HierarchyExpandService';
import type { WorldViewport, HierarchySummary } from './HierarchyExpandService';
import type { UiLayer } from '../common/types';
import { isFiniteViewAffine } from './ViewAffineValidationService';
import { SceneTextGeometryService } from './SceneTextGeometryService';

function identity(): ViewAffine { return { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 }; }
function sourceIdentity(s: ViewSceneSource): string { return JSON.stringify([s.sourceDocumentId, s.sourceId]); }
function indexIdentity(s: ViewSceneSource): string { return JSON.stringify([s.sourceDocumentId, s.sourceId, s.topCellId]); }
function multiply(l: ViewAffine, r: ViewAffine): ViewAffine {
  return { a: l.a * r.a + l.b * r.c, b: l.a * r.b + l.b * r.d,
    c: l.c * r.a + l.d * r.c, d: l.c * r.b + l.d * r.d,
    tx: l.a * r.tx + l.b * r.ty + l.tx, ty: l.c * r.tx + l.d * r.ty + l.ty };
}
function point(m: ViewAffine, p: Point): Point {
  const out: Point = { x: m.a * p.x + m.b * p.y + m.tx, y: m.c * p.x + m.d * p.y + m.ty };
  if (!Number.isFinite(out.x) || !Number.isFinite(out.y)) throw new Error('场景变换坐标无效');
  return out;
}
function bounds(points: Point[]): ShapeBounds {
  const b: ShapeBounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
  for (const p of points) { b.minX = Math.min(b.minX, p.x); b.minY = Math.min(b.minY, p.y);
    b.maxX = Math.max(b.maxX, p.x); b.maxY = Math.max(b.maxY, p.y); }
  return b;
}
function intersects(b: ShapeBounds, v: WorldViewport): boolean {
  return b.minX <= v.maxX && b.maxX >= v.minX && b.minY <= v.maxY && b.maxY >= v.minY;
}
function layer(source: ViewSceneSource, shape: Shape): UiLayer | undefined {
  return source.layers.find((l: UiLayer): boolean => l.layerNumber === shape.layerNumber && l.datatype === shape.datatype);
}
function rgba(hex: string, alpha: number): number[] {
  if (!/^#[0-9a-fA-F]{6}$/.test(hex)) return [0.18, 0.43, 0.96, alpha];
  return [parseInt(hex.substring(1, 3), 16) / 255, parseInt(hex.substring(3, 5), 16) / 255,
    parseInt(hex.substring(5, 7), 16) / 255, alpha];
}
function validateSource(s: ViewSceneSource): void {
  if (!s.sourceId || !s.sourceDocumentId || !Number.isSafeInteger(s.revision) || s.revision < 0 ||
    !Number.isInteger(s.cellId) || s.cellId < 0 || s.cellId >= s.cellNames.length ||
    !Number.isInteger(s.topCellId) || s.topCellId < 0 || s.topCellId >= s.cellNames.length ||
    !Number.isInteger(s.depth) || s.depth < 1 || s.depth > 32 ||
    !Number.isFinite(s.opacity) || s.opacity < 0 || s.opacity > 1 || !isFiniteViewAffine(s.transform)) {
    throw new Error(`来源 ${s.sourceId} 的版本、Cell 或显示变换无效`);
  }
}

interface SceneLayerKey { layerNumber: number; datatype: number; }
interface SceneDefinitionIndex {
  revision: number; shapes: Shape[]; byOwner: Map<number, Shape[]>;
  textTraversalByOwner: Map<number, Shape[]>; textOwners: Set<number>; layerKeys: SceneLayerKey[];
}

/** Scene camera uses the actual positive zoom; the legacy hierarchy helper has
 * a zoom floor which would wrongly cull tiny-scale TEXT/geometry. */
export function sceneViewportFromCamera(width: number, height: number, zoomPercent: number,
  offsetX: number, offsetY: number, marginPx: number = 96): WorldViewport {
  if (![width, height, zoomPercent, offsetX, offsetY, marginPx].every((n: number): boolean => Number.isFinite(n)) ||
    width < 0 || height < 0 || zoomPercent <= 0 || marginPx < 0) throw new Error('场景相机无效');
  const z: number = zoomPercent / 100;
  const pad: number = marginPx / z;
  const vp: WorldViewport = { minX: -offsetX - pad, maxX: Math.max(1, width) / z - offsetX + pad,
    minY: offsetY - Math.max(1, height) / z - pad, maxY: offsetY + pad };
  if (![vp.minX, vp.minY, vp.maxX, vp.maxY].every((n: number): boolean => Number.isFinite(n))) throw new Error('场景相机范围溢出');
  return vp;
}

/** Native-matching PATH outline, before the independent source affine. Absolute
 * WIDTH is built after the hierarchy matrix; source affine then transforms the
 * complete painted contour, including caps and signed type-4 extensions. */
export function scenePathOutline(shape: Shape, hierarchy: ViewAffine): Point[] {
  const width: number = shape.pathWidth ?? 0;
  if (!Number.isFinite(width) || !Number.isFinite(shape.pathBeginExtension ?? 0) ||
    !Number.isFinite(shape.pathEndExtension ?? 0)) throw new Error('PATH 线宽或端扩展无效');
  if (!(width > 0) || shape.points.length < 2) return [];
  const absolute: boolean = shape.pathWidthAbsolute === true;
  let pts: Point[] = [];
  for (const p of shape.points) {
    const q: Point = point(absolute ? hierarchy : identity(), p);
    if (pts.length === 0 || Math.hypot(q.x - pts[pts.length - 1].x, q.y - pts[pts.length - 1].y) > 1e-12) pts.push(q);
  }
  if (pts.length < 2) return [];
  const unit = (x: number, y: number): Point => {
    const len: number = Math.hypot(x, y); return len > 1e-12 ? { x: x / len, y: y / len } : { x: 1, y: 0 };
  };
  if (shape.pathType === 4) {
    const scale: number = absolute ? Math.sqrt(Math.abs(hierarchy.a * hierarchy.d - hierarchy.b * hierarchy.c)) : 1;
    const start: Point = unit(pts[1].x - pts[0].x, pts[1].y - pts[0].y);
    const end: Point = unit(pts[pts.length - 1].x - pts[pts.length - 2].x, pts[pts.length - 1].y - pts[pts.length - 2].y);
    const beginExt: number = (shape.pathBeginExtension ?? 0) * scale;
    const endExt: number = (shape.pathEndExtension ?? 0) * scale;
    pts[0] = { x: pts[0].x - start.x * beginExt, y: pts[0].y - start.y * beginExt };
    pts[pts.length - 1] = { x: pts[pts.length - 1].x + end.x * endExt, y: pts[pts.length - 1].y + end.y * endExt };
    pts = pts.filter((p: Point, i: number): boolean => i === 0 || Math.hypot(p.x - pts[i - 1].x, p.y - pts[i - 1].y) > 1e-12);
    if (pts.length < 2) return [];
  }
  const half: number = width / 2;
  const directions: Point[] = [];
  const offsets: number[] = [];
  for (let i: number = 0; i < pts.length; i++) {
    let direction: Point; let offset: number = half;
    if (i === 0) direction = unit(pts[1].x - pts[0].x, pts[1].y - pts[0].y);
    else if (i === pts.length - 1) direction = unit(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
    else {
      const incoming: Point = unit(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
      const outgoing: Point = unit(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y);
      direction = unit(incoming.x + outgoing.x, incoming.y + outgoing.y);
      const cosine: number = direction.x * incoming.x + direction.y * incoming.y;
      if (Math.abs(cosine) > 1e-12) offset = half / cosine;
    }
    directions.push(direction); offsets.push(offset);
  }
  const out: Point[] = [];
  const edge = (i: number, sign: number, extension: number = 0): Point => ({
    x: pts[i].x - directions[i].y * offsets[i] * sign + directions[i].x * extension,
    y: pts[i].y + directions[i].x * offsets[i] * sign + directions[i].y * extension });
  const cap = (i: number, start: boolean): void => {
    const d: Point = directions[i];
    const angle: number = start ? Math.atan2(-d.x, d.y) : Math.atan2(d.x, -d.y);
    for (let j: number = 0; j <= 8; j++) out.push({ x: pts[i].x + Math.cos(angle - Math.PI * j / 8) * half,
      y: pts[i].y + Math.sin(angle - Math.PI * j / 8) * half });
  };
  if (shape.pathType === 1) cap(0, true);
  else if (shape.pathType === 2) out.push(edge(0, 1, -half));
  for (let i: number = 0; i < pts.length; i++) out.push(edge(i, 1));
  if (shape.pathType === 1) cap(pts.length - 1, false);
  else if (shape.pathType === 2) out.push(edge(pts.length - 1, 1, half), edge(pts.length - 1, -1, half));
  for (let i: number = pts.length - 1; i >= 0; i--) out.push(edge(i, -1));
  if (shape.pathType === 2) out.push(edge(0, -1, -half));
  return absolute ? out : out.map((p: Point): Point => point(hierarchy, p));
}

/** Complete bounded scene consumption; failures return no partial frame. */
export class ViewRenderSceneService {
  private cacheKey: string = '';
  private cacheSources: Shape[][] = [];
  private cache: ViewSceneDrawResult = { primitives: [], overflow: false, limit: 2000, message: '' };
  private indices: Map<string, SceneDefinitionIndex> = new Map<string, SceneDefinitionIndex>();
  private textKey: string = '';
  private textSources: Shape[][] = [];
  private textRequired: boolean = false;
  private textGeometry: SceneTextGeometryService;

  /** Production passes MeasureText with the same fixed monospace font/size as
   * ViewSceneNode. Host/default width is deliberately conservative (2 EM per
   * UTF-16 unit). Explicit node dimensions prevent wrapping beyond this box. */
  constructor(measureTextWidth: (text: string) => number = (text: string): number => text.length * 24) {
    this.textGeometry = new SceneTextGeometryService(instanceTransformMat, measureTextWidth);
  }

  /** Release retained documents after preparation failure or component teardown. */
  clear(): void {
    this.cacheKey = ''; this.cacheSources = [];
    this.cache = { primitives: [], overflow: false, limit: 2000, message: '' };
    this.textKey = ''; this.textSources = []; this.textRequired = false;
    this.indices.clear(); this.textGeometry.clear();
  }

  private textMetrics(text: string): ViewSceneTextMetrics {
    return this.textGeometry.metricsFor(text);
  }

  private glyphAffine(shape: Shape, combined: ViewAffine): ViewAffine {
    return this.textGeometry.glyphTransform(shape, combined);
  }

  private glyphBounds(anchor: Point, transform: ViewAffine, metrics: ViewSceneTextMetrics): ShapeBounds {
    return this.textGeometry.glyphBounds(anchor, transform, metrics);
  }

  private definitionsFor(s: ViewSceneSource): Map<number, Shape[]> {
    const id: string = indexIdentity(s);
    const old: SceneDefinitionIndex | undefined = this.indices.get(id);
    if (old !== undefined && old.revision === s.revision && old.shapes === s.shapes) return old.byOwner;
    const byOwner: Map<number, Shape[]> = new Map<number, Shape[]>();
    const textTraversalByOwner: Map<number, Shape[]> = new Map<number, Shape[]>();
    const textOwners: Set<number> = new Set<number>();
    const layerKeys: Map<string, SceneLayerKey> = new Map<string, SceneLayerKey>();
    for (const shape of s.shapes) {
      const owner: number = shape.ownerCellId ?? s.topCellId;
      const group: Shape[] = byOwner.get(owner) ?? []; group.push(shape); byOwner.set(owner, group);
      if (shape.type === ShapeType.TEXT || shape.type === ShapeType.INSTANCE) {
        const textGroup: Shape[] = textTraversalByOwner.get(owner) ?? []; textGroup.push(shape); textTraversalByOwner.set(owner, textGroup);
        if (shape.type === ShapeType.TEXT) textOwners.add(owner);
      }
      if (shape.type !== ShapeType.INSTANCE && shape.type !== ShapeType.NODE) layerKeys.set(`${shape.layerNumber}/${shape.datatype}`,
        { layerNumber: shape.layerNumber, datatype: shape.datatype });
    }
    this.indices.set(id, { revision: s.revision, shapes: s.shapes, byOwner: byOwner,
      textTraversalByOwner: textTraversalByOwner, textOwners: textOwners, layerKeys: Array.from(layerKeys.values()) });
    return byOwner;
  }

  private sameDefinitions(sources: ViewSceneSource[], previous: Shape[][]): boolean {
    return sources.length === previous.length && sources.every((s: ViewSceneSource, i: number): boolean => s.shapes === previous[i]);
  }

  private hasReachableText(s: ViewSceneSource, definitions: SceneDefinitionIndex): boolean {
    if (s.opacity === 0 || definitions.textOwners.size === 0) return false;
    const cells: Set<number> = new Set<number>([s.cellId]);
    for (let depth: number = 1; depth <= s.depth; depth++) {
      const next: Set<number> = new Set<number>();
      for (const id of cells) for (const shape of definitions.textTraversalByOwner.get(id) ?? []) {
        if (shape.type === ShapeType.TEXT && shape.points.length > 0 && (shape.text ?? '').length > 0 && layer(s, shape)?.visible !== false) return true;
        if (shape.type === ShapeType.INSTANCE && shape.cellId !== undefined) next.add(shape.cellId);
      }
      cells.clear(); for (const id of next) cells.add(id);
      if (cells.size === 0) break;
    }
    return false;
  }

  private hasStoppedReferences(s: ViewSceneSource, definitions: SceneDefinitionIndex): boolean {
    if (s.opacity === 0) return false;
    let cells: Set<number> = new Set<number>([s.cellId]);
    for (let depth: number = 1; depth <= s.depth; depth++) {
      const next: Set<number> = new Set<number>();
      for (const id of cells) for (const shape of definitions.textTraversalByOwner.get(id) ?? []) {
        if (shape.type !== ShapeType.INSTANCE) continue;
        if (depth === s.depth) return true;
        if (shape.cellId !== undefined) next.add(shape.cellId);
      }
      cells = next; if (cells.size === 0) break;
    }
    return false;
  }

  sourceKey(sources: ViewSceneSource[]): string {
    if (sources.length > 65) throw new Error('只读场景最多包含底图及 64 个来源');
    const ids: Set<string> = new Set<string>();
    const key: string = sources.map((s: ViewSceneSource): string => {
      validateSource(s); const id: string = sourceIdentity(s);
      if (ids.has(id)) throw new Error('场景来源身份重复'); ids.add(id);
      return JSON.stringify([id, s.revision, s.cellId, s.topCellId, s.cellNames, s.depth, s.transform, s.opacity, s.readOnly, layerRenderStyle(undefined),
        s.layers.map((l: UiLayer) => [l.layerNumber, l.datatype, l.visible, l.color, l.transparency,
          l.fillStyle, l.lineStyle, l.lineWidth, l.highlighted, l.animated])]);
    }).join('|');
    for (const id of this.indices.keys()) {
      if (!sources.some((s: ViewSceneSource): boolean => indexIdentity(s) === id)) this.indices.delete(id);
    }
    if (this.cacheSources.some((shapes: Shape[]): boolean => !sources.some((s: ViewSceneSource): boolean => s.shapes === shapes))) {
      this.cacheKey = ''; this.cacheSources = [];
      this.cache = { primitives: [], overflow: false, limit: 2000, message: '' };
    }
    return key;
  }

  nativeSources(sources: ViewSceneSource[]): NativeRenderSceneSource[] {
    this.sourceKey(sources);
    return sources.map((s: ViewSceneSource): NativeRenderSceneSource => {
      const styles: NativeLayerRenderStyle[] = s.layers.map((l: UiLayer): NativeLayerRenderStyle => {
        const st = layerRenderStyle(l);
        const fillPattern: number = fillPatternForHatch(st.hatch);
        const glStrokeOnly: boolean = st.strokeOnly && fillPattern === 0;
        return {
          layerNumber: l.layerNumber,
          datatype: l.datatype,
          visible: l.visible,
          color: rgba(l.color, glStrokeOnly ? st.strokeOpacity : st.fillOpacity),
          strokeOnly: glStrokeOnly,
          fillPattern: fillPattern,
        };
      });
      this.definitionsFor(s);
      const definitions: SceneDefinitionIndex | undefined = this.indices.get(indexIdentity(s));
      if (definitions !== undefined) for (const key of definitions.layerKeys) {
        if (styles.some((style: NativeLayerRenderStyle): boolean => style.layerNumber === key.layerNumber && style.datatype === key.datatype)) continue;
        const st = layerRenderStyle(undefined);
        styles.push({ layerNumber: key.layerNumber, datatype: key.datatype, visible: true,
          color: rgba('#2F6DF6', st.fillOpacity), strokeOnly: false, fillPattern: 0 });
      }
      const packed = packShapesCoordinates(s.shapes, 8192);
      return { sourceId: sourceIdentity(s), revision: s.revision,
        snapshot: {
          shapes: s.shapes,
          cellNames: s.cellNames,
          topCellId: s.topCellId,
          packedCoords: packed.packedCoords,
          shapePointOffsets: packed.shapePointOffsets,
          shapePointCounts: packed.shapePointCounts,
        },
        cellId: s.cellId, depth: s.depth, transform: s.transform, opacity: s.opacity, styles: styles };
    });
  }

  /**
   * OpenGL C++ 主路径现已原生绘制全部多边形/路径几何及未展开子实例边界框（RECT_OUTLINE），
   * 可见 TEXT 标签则由 LayoutCanvasView 在 glActive=true 时通过 drawTextOverlays 独立叠层绘制，
   * 绝不再因存在未展开子实例或 TEXT 标签而强制关闭 GPU 退回 20 万顶点上限的 ArkUI 软渲染。
   */
  requiresArkUi(sources: ViewSceneSource[], _viewport: WorldViewport, _zoomPercent: number = 100): boolean {
    this.sourceKey(sources);
    return false;
  }

  /** 仅提取当前视口可见的 TEXT 标签图元供 GPU 画布上方轻量叠层渲染（远景 <0.5% 自动隐藏亚像素文字） */
  drawTextOverlays(sources: ViewSceneSource[], viewport: WorldViewport,
    limit: number = 256, zoomPercent: number = 100): ViewScenePrimitive[] {
    if (!Number.isFinite(zoomPercent) || zoomPercent < 0.5) {
      return [];
    }
    let hasAnyText: boolean = false;
    for (const s of sources) {
      if (s.opacity === 0) continue;
      this.definitionsFor(s);
      const definitions: SceneDefinitionIndex | undefined = this.indices.get(indexIdentity(s));
      if (definitions !== undefined && this.hasReachableText(s, definitions)) {
        hasAnyText = true;
        break;
      }
    }
    if (!hasAnyText) {
      return [];
    }
    const res: ViewSceneDrawResult = this.draw(sources, viewport, limit, zoomPercent, true);
    if (res.overflow) {
      return [];
    }
    return res.primitives.filter((p: ViewScenePrimitive): boolean => p.kind === 'text');
  }

  draw(sources: ViewSceneSource[], viewport: WorldViewport, limit: number = 2000,
    zoomPercent: number = 100, textOnly: boolean = false): ViewSceneDrawResult {
    try {
      const key: string = `${this.sourceKey(sources)}:${JSON.stringify(viewport)}:${limit}:${zoomPercent}:${textOnly}`;
      if (key === this.cacheKey && this.sameDefinitions(sources, this.cacheSources)) return this.cache;
      if (!Number.isSafeInteger(limit) || limit < 0 || ![viewport.minX, viewport.minY, viewport.maxX, viewport.maxY]
        .every((n: number): boolean => Number.isFinite(n)) || viewport.maxX < viewport.minX || viewport.maxY < viewport.minY ||
        !Number.isFinite(zoomPercent) || zoomPercent <= 0) throw new Error('场景视口或预算无效');
      const primitives: ViewScenePrimitive[] = [];
      let nodes: number = 0; let points: number = 0;
      for (const s of sources) {
        if (s.opacity === 0) continue;
        this.definitionsFor(s);
        const definitions: SceneDefinitionIndex | undefined = this.indices.get(indexIdentity(s));
        if (definitions === undefined) continue;
        if (textOnly && !this.hasReachableText(s, definitions)) continue;
        const byOwner: Map<number, Shape[]> = textOnly ? definitions.textTraversalByOwner : definitions.byOwner;
        const sourcePrimitives: ViewScenePrimitive[] = [];
        let referenceBounds: HierarchyReferenceBoundsResolver | undefined;
        const visit = (cellId: number, hierarchy: ViewAffine, depth: number, path: number[], token: string): void => {
          if (path.indexOf(cellId) >= 0) throw new Error(`来源 ${s.sourceId} 包含循环实例`);
          for (const shape of byOwner.get(cellId) ?? []) {
            if (++nodes > 500000) throw new Error('场景遍历超出预算，请放大局部或降低层级');
            if (shape.type === ShapeType.NODE) continue;
            if (shape.type === ShapeType.INSTANCE) {
              if (shape.cellId === undefined || shape.cellId < 0 || shape.cellId >= s.cellNames.length) throw new Error('场景实例引用无效');
              if (depth <= 1) {
                if (textOnly) continue;
                if (referenceBounds === undefined) referenceBounds = new HierarchyReferenceBoundsResolver(s.shapes, s.topCellId,
                  (number: number, datatype: number): boolean => s.layers.find((l: UiLayer): boolean =>
                    l.layerNumber === number && l.datatype === datatype)?.visible !== false, s.cellNames.length);
                const reference: HierarchySummary = referenceBounds.summaryForInstance(shape);
                const b: ShapeBounds | undefined = reference.bounds;
                if (b === undefined) continue;
                const combined: ViewAffine = multiply(s.transform, hierarchy);
                const corners: Point[] = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY },
                  { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }];
                const scale: number = Math.sqrt(Math.abs(hierarchy.a * hierarchy.d - hierarchy.b * hierarchy.c));
                const pad: number = reference.absolutePathPadding * Math.max(0, 1 - scale);
                let polygon: Point[];
                if (pad > 0) {
                  const world: ShapeBounds = bounds(corners.map((p: Point): Point => point(hierarchy, p)));
                  const paddedCorners: Point[] = [{ x: world.minX - pad, y: world.minY - pad }, { x: world.maxX + pad, y: world.minY - pad },
                    { x: world.maxX + pad, y: world.maxY + pad }, { x: world.minX - pad, y: world.maxY + pad }];
                  polygon = paddedCorners.map((p: Point): Point => point(s.transform, p));
                } else polygon = corners.map((p: Point): Point => point(combined, p));
                if (!intersects(bounds(polygon), viewport)) continue;
                const style = layerRenderStyle(undefined);
                style.fillOpacity = 0; style.strokeOnly = true; style.strokeOpacity = 0.55;
                style.strokeWidth = 1; style.dashArray = [4, 3]; style.hatch = ''; style.highlighted = false; style.animated = false;
                sourcePrimitives.push({ key: JSON.stringify([s.sourceDocumentId, s.sourceId, s.revision, token, 'frame', shape.id,
                  s.depth, s.transform, combined, polygon, s.opacity]), sourceId: s.sourceId, sourceDocumentId: s.sourceDocumentId,
                  hierarchyFrame: true, layerNumber: shape.layerNumber, datatype: shape.datatype, kind: 'polygon', points: polygon,
                  text: '', textTransform: identity(), textWidth: 0, textHeight: 0, color: '#8192A6', style, opacity: s.opacity });
                if (primitives.length + sourcePrimitives.length > limit) throw new Error('内置场景超过图元预算，请放大局部或提高层级');
                continue;
              }
              const cols: number = shape.arrayCols || 1; const rows: number = shape.arrayRows || 1;
              if (!Number.isSafeInteger(cols) || !Number.isSafeInteger(rows) || cols < 1 || rows < 1) throw new Error('场景阵列维数无效');
              const instanceMatrix = instanceTransformMat(shape);
              const inst: ViewAffine = { a: instanceMatrix.a, b: instanceMatrix.b, c: instanceMatrix.c,
                d: instanceMatrix.d, tx: instanceMatrix.tx, ty: instanceMatrix.ty };
              for (let row: number = 0; row < rows; row++) for (let col: number = 0; col < cols; col++) {
                if (++nodes > 500000) throw new Error('场景阵列遍历超出预算，请放大局部或降低层级');
                const member: ViewAffine = { a: inst.a, b: inst.b, c: inst.c, d: inst.d,
                  tx: inst.tx + col * (shape.arrayColStepX ?? 0) + row * (shape.arrayRowStepX ?? 0),
                  ty: inst.ty + col * (shape.arrayColStepY ?? 0) + row * (shape.arrayRowStepY ?? 0) };
                visit(shape.cellId, multiply(hierarchy, member), depth - 1, path.concat([cellId]), `${token}/${shape.id}:${row}:${col}`);
              }
              continue;
            }
            const uiLayer: UiLayer | undefined = layer(s, shape); if (uiLayer?.visible === false || shape.points.length === 0) continue;
            if (textOnly && shape.type !== ShapeType.TEXT) continue;
            points += shape.points.length; if (points > 2500000) throw new Error('场景顶点超过预算');
            const combined: ViewAffine = multiply(s.transform, hierarchy);
            let polygon: Point[]; let textTransform: ViewAffine = identity();
            let textWidth: number = 0; let textHeight: number = 0;
            if (shape.type === ShapeType.PATH) polygon = scenePathOutline(shape, hierarchy).map((p: Point): Point => point(s.transform, p));
            else if (shape.type === ShapeType.RECT) {
              const b: ShapeBounds = getShapeBounds(shape);
              const corners: Point[] = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY },
                { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }];
              polygon = corners.map((p: Point): Point => point(combined, p));
            } else if (shape.type === ShapeType.TEXT) polygon = [point(combined, shape.points[0])];
            else polygon = shape.points.map((p: Point): Point => point(combined, p));
            if (polygon.length === 0) continue;
            if (shape.type !== ShapeType.TEXT && !intersects(bounds(polygon), viewport)) continue;
            if (shape.type === ShapeType.TEXT) {
              const text: string = shape.text ?? ''; if (text.length === 0) continue;
              const metrics: ViewSceneTextMetrics = this.textMetrics(text);
              textTransform = this.glyphAffine(shape, combined);
              if (!intersects(this.glyphBounds(polygon[0], textTransform, metrics), viewport)) continue;
              textWidth = metrics.width; textHeight = metrics.height;
            }
            const style = layerRenderStyle(uiLayer);
            sourcePrimitives.push({ key: JSON.stringify([s.sourceDocumentId, s.sourceId, s.revision, token, shape.id,
              s.transform, combined, s.opacity, uiLayer?.color ?? '#2F6DF6', style, polygon, shape.text ?? '', textTransform, textWidth, textHeight]),
              sourceId: s.sourceId, sourceDocumentId: s.sourceDocumentId,
              layerNumber: shape.layerNumber, datatype: shape.datatype,
              kind: shape.type === ShapeType.TEXT ? 'text' : 'polygon', points: polygon, text: shape.text ?? '',
              textTransform: textTransform, textWidth: textWidth, textHeight: textHeight,
              color: uiLayer?.color ?? '#2F6DF6', style: style, opacity: s.opacity });
            if (primitives.length + sourcePrimitives.length > limit) throw new Error('内置场景超过 2000 图元预算，请放大局部或降低层级');
          }
        };
        visit(s.cellId, identity(), s.depth, [], 'root');
        // Native orders layer/datatype inside each source. Source order remains
        // the outer paint order, including TEXT; never sort the merged array.
        sourcePrimitives.sort((a: ViewScenePrimitive, b: ViewScenePrimitive): number => {
          return a.layerNumber - b.layerNumber || a.datatype - b.datatype;
        });
        primitives.push(...sourcePrimitives);
      }
      this.cacheKey = key; this.cacheSources = sources.map((s: ViewSceneSource): Shape[] => s.shapes);
      this.cache = { primitives: primitives, overflow: false, limit: limit, message: '' }; return this.cache;
    } catch (e) {
      this.cacheKey = ''; this.cacheSources = [];
      // Atomic rejection must also release the previous frame's derived points/keys.
      this.cache = { primitives: [], overflow: true, limit: limit, message: `当前场景未完整绘制：${e}` };
      return this.cache;
    }
  }
}
