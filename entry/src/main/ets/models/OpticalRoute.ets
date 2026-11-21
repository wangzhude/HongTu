import type { Point, Shape } from './GdsiiData';
import type { ResolvedPort } from './LayoutPort';
import type { RouteMaterialProfile, RouteMaterialCap, RouteTaperRule } from './RouteMaterial';

export interface OpticalRouteBounds { minX: number; minY: number; maxX: number; maxY: number; }
export interface OpticalPortTolerance {
  maximumCenterErrorNm: number; maximumAngleErrorDeg: number; maximumWidthErrorNm: number;
}
export interface OpticalRouteBudget {
  maximumSamples?: number; maximumVertices?: number; maximumMaterials?: number;
  maximumWork?: number; maximumSolverIntervals?: number;
}
export interface OpticalRouteObstacle {
  key: string; pointsNm: Point[]; layerNumber: number; datatype: number;
  /** Source clearance and prior-route separation remain distinct constraints. */
  clearanceNm?: number;
}
export interface OpticalBboxSection { layerNumber: number; datatype: number; offsetNm: number; }
export interface OpticalRouteRequest {
  start: ResolvedPort; end: ResolvedPort; dbuNm: number; ownerCellId: number; firstShapeId: number;
  /** Actual world-frame bands returned by RouteMaterialService.inspect, not a nominal width. */
  materialProfile: RouteMaterialProfile;
  bend: 'circular' | 'euler' | 's-bend';
  /** Minimum centerline curvature radius, never the effective corner setback. */
  minimumRadiusNm: number;
  /** Fraction of total turning angle occupied by the two Euler ramps; defaults to 0.5. */
  eulerFraction?: number;
  maximumDeviationNm: number;
  coordinatePolicy?: 'strict' | 'quantize-interior' | 'quantize-with-port-tolerance';
  /** Mandatory for quantized ports; no tolerance is invented by the engine. */
  portTolerance?: OpticalPortTolerance;
  startLeadNm?: number; endLeadNm?: number;
  boundsNm?: OpticalRouteBounds;
  /** Corner-control backbone. Rounded bends do NOT pass through the trimmed corners. */
  backboneNm?: Point[];
  obstacles?: OpticalRouteObstacle[]; clearanceNm?: number;
  /** These are explicitly rectangular bbox enclosures, not continuous waveguide strips. */
  bboxSections?: OpticalBboxSection[];
  /** Required with linear-taper profiles; geometry validates the original rule. */
  taperRule?: RouteTaperRule;
  /** Actual continuous arc length; the solver inserts physical bend/straight meanders. */
  targetLengthNm?: number; lengthToleranceNm?: number;
  budget?: OpticalRouteBudget;
}
export interface OpticalCurvePrimitive {
  kind: 'straight' | 'circular' | 'euler'; startNm: Point; startHeadingRad: number;
  lengthNm: number; turnRad: number; minimumRadiusNm: number; eulerFraction: number;
  startStationNm: number;
}
export interface OpticalCurveSample {
  pointNm: Point; stationNm: number; headingRad: number; curvaturePerNm: number;
}
export interface OpticalPortError {
  portId: string; centerErrorNm: number; angleErrorDeg: number; widthErrorNm: number;
}
export interface OpticalMaterialSource { shapeId: number; materialId: string; kind: 'strip' | 'bbox'; }
export interface OpticalRouteGeometry {
  shapes: Shape[]; profile: RouteMaterialProfile; endpointCaps: RouteMaterialCap[];
  endpointErrors: OpticalPortError[]; materialSources: OpticalMaterialSource[];
  centerlineNm: Point[]; samples: OpticalCurveSample[]; primitives: OpticalCurvePrimitive[];
  continuousLengthNm: number; sampledLengthNm: number; minimumRadiusNm?: number; maximumCurvaturePerNm: number;
  curvatureContinuous: boolean; maximumDeviationNm: number; samplingErrorNm: number;
  integrationErrorNm: number; quantizationErrorNm: number; poseClosureErrorNm: number;
  solverMode: string; candidateCount: number; rejectedCandidates: number;
  workUsed: number; warnings: string[];
}
export interface OpticalRouteResult { ok: boolean; message: string; route?: OpticalRouteGeometry; }
export interface OpticalRouteCertificate { ok: boolean; message: string; workUsed: number; }
export interface OpticalBendRequest {
  kind: 'circular' | 'euler'; minimumRadiusNm: number; turnDeg: number; eulerFraction?: number;
  maximumDeviationNm: number; budget?: OpticalRouteBudget;
}
export interface OpticalBendGeometry {
  samples: OpticalCurveSample[]; primitive: OpticalCurvePrimitive; continuousLengthNm: number;
  minimumRadiusNm: number; effectiveRadiusNm?: number; tangentSetbackNm?: number;
  samplingErrorNm: number; integrationErrorNm: number;
}
