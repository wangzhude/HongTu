import type { ViewAffine } from '../models/ViewWorkspace';

/** Match the complete scene/native contract without an arbitrary determinant epsilon. */
export function isFiniteViewAffine(value: ViewAffine): boolean {
  const coefficients: number[] = [value.a, value.b, value.c, value.d, value.tx, value.ty];
  if (!coefficients.every((coefficient: number): boolean => Number.isFinite(coefficient))) return false;
  const determinant: number = value.a * value.d - value.b * value.c;
  if (!Number.isFinite(determinant) || determinant === 0) return false;
  // Divide each numerator directly. Computing 1/determinant first can overflow
  // even when every inverse coefficient below is representable and finite.
  const inverse: number[] = [value.d / determinant, -value.b / determinant,
    -value.c / determinant, value.a / determinant,
    (value.b * value.ty - value.d * value.tx) / determinant,
    (value.c * value.tx - value.a * value.ty) / determinant];
  return inverse.every((coefficient: number): boolean => Number.isFinite(coefficient));
}
