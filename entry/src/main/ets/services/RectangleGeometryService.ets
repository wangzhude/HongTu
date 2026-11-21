/** Read-only validation of the two native RECT encodings. Licensed under GPLv3. */
import type { Point } from '../models/GdsiiData';

/** Return fresh axis-aligned corners; never rewrite the source point array. */
export function strictRectangleCorners(points: Point[]): Point[] {
  const message: string = '矩形需为两个对角点或四个循序轴对齐角点，且有有效面积';
  if (!Array.isArray(points) || (points.length !== 2 && points.length !== 4) ||
    points.some((point: Point): boolean => point === undefined || point === null ||
      !Number.isFinite(point.x) || !Number.isFinite(point.y))) throw new Error(message);
  const minX: number = Math.min(...points.map((point: Point): number => point.x));
  const minY: number = Math.min(...points.map((point: Point): number => point.y));
  const maxX: number = Math.max(...points.map((point: Point): number => point.x));
  const maxY: number = Math.max(...points.map((point: Point): number => point.y));
  if (minX >= maxX || minY >= maxY) throw new Error(message);
  if (points.length === 4) {
    for (let i: number = 0; i < points.length; i++) {
      const point: Point = points[i], next: Point = points[(i + 1) % points.length];
      if ((point.x !== minX && point.x !== maxX) || (point.y !== minY && point.y !== maxY) ||
        (point.x === next.x) === (point.y === next.y)) throw new Error(message);
      for (let j: number = 0; j < i; j++) {
        if (points[j].x === point.x && points[j].y === point.y) throw new Error(message);
      }
    }
  }
  return [{ x: minX, y: minY }, { x: maxX, y: minY },
    { x: maxX, y: maxY }, { x: minX, y: maxY }];
}
