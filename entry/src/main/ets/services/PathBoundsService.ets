/** PATH painted bounds, matching Triangulator::pathOutline and
 * scene_graph::effectivePolygonTransformed. This accumulates outline extrema
 * without allocating the complete outline. This file is licensed under GPLv3.
 */
import type { Shape, Point, ShapeBounds } from '../models/GdsiiData';

export interface PathBoundsTransform {
  a: number;
  b: number;
  c: number;
  d: number;
  tx: number;
  ty: number;
}

function identityTransform(): PathBoundsTransform {
  return { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };
}

function transformPoint(p: Point, m: PathBoundsTransform): Point {
  return { x: m.a * p.x + m.b * p.y + m.tx, y: m.c * p.x + m.d * p.y + m.ty };
}

function invalidBounds(): ShapeBounds {
  return { minX: NaN, minY: NaN, maxX: NaN, maxY: NaN };
}

function finitePoint(p: Point): boolean {
  return Number.isFinite(p.x) && Number.isFinite(p.y);
}

function difference(a: Point, b: Point): Point {
  return { x: a.x - b.x, y: a.y - b.y };
}

function unitOr(p: Point, fallback: Point): Point {
  const length: number = Math.sqrt(p.x * p.x + p.y * p.y);
  if (!(length > 1e-12) || !Number.isFinite(length)) return fallback;
  const inverse: number = 1 / length;
  return { x: p.x * inverse, y: p.y * inverse };
}

function distanceSquared(a: Point, b: Point): number {
  const x: number = a.x - b.x;
  const y: number = a.y - b.y;
  return x * x + y * y;
}

class BoundsAccumulator {
  private bounds: ShapeBounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
  private valid: boolean = true;
  private transform: PathBoundsTransform;
  private hitTest: PathHitAccumulator | undefined;

  constructor(transform: PathBoundsTransform, hitTest?: PathHitAccumulator) {
    this.transform = transform;
    this.hitTest = hitTest;
  }

  add(p: Point): void {
    const point: Point = transformPoint(p, this.transform);
    if (!finitePoint(point)) {
      this.valid = false;
      return;
    }
    this.bounds.minX = Math.min(this.bounds.minX, point.x);
    this.bounds.minY = Math.min(this.bounds.minY, point.y);
    this.bounds.maxX = Math.max(this.bounds.maxX, point.x);
    this.bounds.maxY = Math.max(this.bounds.maxY, point.y);
    if (this.hitTest !== undefined) this.hitTest.add(point);
  }

  result(): ShapeBounds {
    return this.valid ? this.bounds : invalidBounds();
  }
}

/** Streams the ordered outline, including the closing edge, without storing it. */
class PathHitAccumulator {
  private first: Point | undefined;
  private previous: Point | undefined;
  private target: Point;
  private toleranceSquared: number;
  private inside: boolean = false;
  private nearEdge: boolean = false;

  constructor(x: number, y: number, tolerance: number) {
    this.target = { x: x, y: y };
    this.toleranceSquared = tolerance * tolerance;
  }

  add(point: Point): void {
    if (this.first === undefined) this.first = point;
    if (this.previous !== undefined) this.edge(this.previous, point);
    this.previous = point;
  }

  private edge(a: Point, b: Point): void {
    const dx: number = b.x - a.x;
    const dy: number = b.y - a.y;
    const lengthSquared: number = dx * dx + dy * dy;
    const position: number = lengthSquared < 1e-18 ? 0 : Math.max(0, Math.min(1,
      ((this.target.x - a.x) * dx + (this.target.y - a.y) * dy) / lengthSquared));
    const ex: number = this.target.x - (a.x + position * dx);
    const ey: number = this.target.y - (a.y + position * dy);
    if (ex * ex + ey * ey <= this.toleranceSquared) this.nearEdge = true;
    if ((a.y > this.target.y) !== (b.y > this.target.y)) {
      const crossing: number = a.x + (this.target.y - a.y) / (b.y - a.y) * (b.x - a.x);
      if (this.target.x < crossing) this.inside = !this.inside;
    }
  }

  result(): boolean {
    if (this.previous === undefined || this.first === undefined) return false;
    this.edge(this.previous, this.first);
    return this.inside || this.nearEdge;
  }
}

interface PathFrame {
  left: Point;
  right: Point;
  direction: Point;
}

function pathFrame(points: Point[], index: number, halfWidth: number): PathFrame {
  let direction: Point;
  let offset: number = halfWidth;
  if (index === 0) {
    direction = difference(points[1], points[0]);
  } else if (index === points.length - 1) {
    direction = difference(points[index], points[index - 1]);
  } else {
    const incoming: Point = unitOr(difference(points[index], points[index - 1]), { x: 1, y: 0 });
    const outgoing: Point = unitOr(difference(points[index + 1], points[index]), incoming);
    direction = unitOr({ x: incoming.x + outgoing.x, y: incoming.y + outgoing.y }, outgoing);
    const cosine: number = direction.x * incoming.x + direction.y * incoming.y;
    if (Math.abs(cosine) > 1e-12) offset = halfWidth / cosine;
  }
  direction = unitOr(direction, { x: 1, y: 0 });
  return {
    direction: direction,
    left: { x: points[index].x - direction.y * offset, y: points[index].y + direction.x * offset },
    right: { x: points[index].x + direction.y * offset, y: points[index].y - direction.x * offset }
  };
}

function roundCap(output: BoundsAccumulator, center: Point, direction: Point, halfWidth: number, start: boolean): void {
  const angle: number = start ? Math.atan2(-direction.x, direction.y) : Math.atan2(direction.x, -direction.y);
  for (let segment: number = 0; segment <= 8; segment++) {
    const a: number = angle - Math.PI * segment / 8;
    output.add({ x: center.x + Math.cos(a) * halfWidth, y: center.y + Math.sin(a) * halfWidth });
  }
}

/** Undefined means a degenerate/unpainted PATH. Non-finite input or output
 * returns non-finite bounds so the caller's normal bounds validation rejects
 * the operation instead of silently omitting malformed geometry.
 */
export function getPathGeometryBounds(shape: Shape, transform?: PathBoundsTransform): ShapeBounds | undefined {
  return evaluatePathGeometry(shape, transform);
}

/** Filled-outline or world-space edge-tolerance hit; never a bounding-box hit.
 * The outline matches native cap/join sampling and absolute WIDTH transforms.
 */
export function pathGeometryContains(shape: Shape, x: number, y: number, tolerance: number,
  transform?: PathBoundsTransform): boolean {
  if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(tolerance) || tolerance < 0) return false;
  const hit: PathHitAccumulator = new PathHitAccumulator(x, y, tolerance);
  const bounds: ShapeBounds | undefined = evaluatePathGeometry(shape, transform, hit);
  if (bounds === undefined || !Number.isFinite(bounds.minX) || !Number.isFinite(bounds.minY) ||
    !Number.isFinite(bounds.maxX) || !Number.isFinite(bounds.maxY)) return false;
  return hit.result();
}

function evaluatePathGeometry(shape: Shape, transform?: PathBoundsTransform,
  hitTest?: PathHitAccumulator): ShapeBounds | undefined {
  const m: PathBoundsTransform = transform ?? identityTransform();
  if (!Number.isFinite(m.a) || !Number.isFinite(m.b) || !Number.isFinite(m.c) ||
    !Number.isFinite(m.d) || !Number.isFinite(m.tx) || !Number.isFinite(m.ty)) return invalidBounds();
  const width: number = shape.pathWidth ?? 0;
  const pathType: number = shape.pathType ?? 0;
  let beginExtension: number = shape.pathBeginExtension ?? 0;
  let endExtension: number = shape.pathEndExtension ?? 0;
  if (!Number.isFinite(width) || !Number.isFinite(pathType) || !Number.isFinite(beginExtension) ||
    !Number.isFinite(endExtension)) return invalidBounds();
  if (shape.points.length < 2 || !(width > 0)) return undefined;
  let points: Point[] = [];
  const absoluteWidth: boolean = shape.pathWidthAbsolute === true;
  for (const point of shape.points) {
    if (!finitePoint(point)) return invalidBounds();
    const p: Point = absoluteWidth ? transformPoint(point, m) : { x: point.x, y: point.y };
    if (!finitePoint(p)) return invalidBounds();
    points.push(p);
  }
  if (absoluteWidth) {
    const scale: number = Math.sqrt(Math.abs(m.a * m.d - m.b * m.c));
    if (!Number.isFinite(scale)) return invalidBounds();
    beginExtension *= scale;
    endExtension *= scale;
  }
  if (pathType === 4) {
    let first: number = 1;
    let last: number = points.length - 2;
    while (first < points.length && distanceSquared(points[first], points[0]) < 1e-24) first++;
    while (last > 0 && distanceSquared(points[points.length - 1], points[last]) < 1e-24) last--;
    if (first >= points.length) return undefined;
    const begin: Point = points[0];
    const end: Point = points[points.length - 1];
    const startDirection: Point = unitOr(difference(points[first], begin), { x: 1, y: 0 });
    const endDirection: Point = unitOr(difference(end, points[last]), { x: 1, y: 0 });
    points = points.slice(first - 1);
    while (points.length > 2 && distanceSquared(points[points.length - 1], points[points.length - 2]) < 1e-24) points.pop();
    points[0] = { x: begin.x - startDirection.x * beginExtension, y: begin.y - startDirection.y * beginExtension };
    points[points.length - 1] = { x: end.x + endDirection.x * endExtension, y: end.y + endDirection.y * endExtension };
  }
  const clean: Point[] = [];
  for (const point of points) {
    if (!finitePoint(point)) return invalidBounds();
    if (clean.length > 0 && Math.abs(point.x - clean[clean.length - 1].x) <= 1e-12 &&
      Math.abs(point.y - clean[clean.length - 1].y) <= 1e-12) continue;
    clean.push(point);
  }
  if (clean.length < 2) return undefined;
  const halfWidth: number = width * 0.5;
  const output: BoundsAccumulator = new BoundsAccumulator(absoluteWidth ? identityTransform() : m, hitTest);
  const capMode: number = pathType === 1 ? 1 : (pathType === 2 ? 2 : 0);
  const start: PathFrame = pathFrame(clean, 0, halfWidth);
  const end: PathFrame = pathFrame(clean, clean.length - 1, halfWidth);
  // Preserve native outline order: start cap, left forward, end cap, right back.
  if (capMode === 1) {
    roundCap(output, clean[0], start.direction, halfWidth, true);
  } else if (capMode === 2) {
    output.add({ x: start.left.x - start.direction.x * halfWidth, y: start.left.y - start.direction.y * halfWidth });
  }
  for (let i: number = 0; i < clean.length; i++) {
    output.add(pathFrame(clean, i, halfWidth).left);
  }
  if (capMode === 1) {
    roundCap(output, clean[clean.length - 1], end.direction, halfWidth, false);
  } else if (capMode === 2) {
    output.add({ x: end.left.x + end.direction.x * halfWidth, y: end.left.y + end.direction.y * halfWidth });
    output.add({ x: end.right.x + end.direction.x * halfWidth, y: end.right.y + end.direction.y * halfWidth });
  }
  for (let i: number = clean.length - 1; i >= 0; i--) {
    output.add(pathFrame(clean, i, halfWidth).right);
  }
  if (capMode === 2) {
    output.add({ x: start.right.x - start.direction.x * halfWidth, y: start.right.y - start.direction.y * halfWidth });
  }
  return output.result();
}
