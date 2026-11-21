import type { Point, Shape } from './GdsiiData';
import type { PortEndpoint, ResolvedPort } from './LayoutPort';
import type { EditStructureState } from '../services/EditService';
import type { RouteBounds, PlannedRoute, RoutePlannerBudget, RoutePlannerStats } from '../services/RoutePlannerService';
import type { RouteMaterialBudget, RouteMaterialProfile, RouteMaterialResult } from './RouteMaterial';
import type { RouteObstacleBudget } from '../services/RouteObstacleService';
import type { OpticalPortTolerance, OpticalRouteBudget, OpticalRouteGeometry } from './OpticalRoute';

export interface RouteSessionContext {
  documentIdentity: string;
  structure: EditStructureState;
  /** Exact current technology serialization; an empty string means no active technology. */
  technologyJson: string;
}
export interface RouteSessionPair {
  key: string; start: PortEndpoint; end: PortEndpoint;
  waypointsNm?: Point[]; targetLengthNm?: number;
  descriptorJson?: string; endDescriptorJson?: string; transitionRuleJson?: string;
}
export interface RouteSessionBudget {
  maximumSourceShapes?: number; maximumSourcePoints?: number;
  maximumCandidateShapes?: number; maximumCandidateVertices?: number; maximumValidationWork?: number;
}
export interface RouteSessionRequest {
  pairs: RouteSessionPair[]; boundsNm: RouteBounds;
  clearanceNm: number; separationNm: number; leadNm: number; gridNm: number;
  matchLengths: boolean; targetLengthNm?: number; lengthToleranceNm?: number;
  coordinatePolicy?: 'strict' | 'quantize-interior';
  plannerBudget?: RoutePlannerBudget; materialBudget?: RouteMaterialBudget; obstacleBudget?: RouteObstacleBudget;
  sessionBudget?: RouteSessionBudget;
  /** Enables actual optical curves for optical pairs; electrical pairs keep
   * their physical polyline semantics. Waypoints become corner controls. */
  optical?: RouteSessionOpticalSettings;
}
export interface RouteSessionOpticalSettings {
  bend: 'circular' | 'euler' | 's-bend'; minimumRadiusNm: number;
  eulerFraction?: number; maximumDeviationNm: number;
  coordinatePolicy?: 'strict' | 'quantize-interior' | 'quantize-with-port-tolerance';
  portTolerance?: OpticalPortTolerance; budget?: OpticalRouteBudget;
}
export interface RouteSessionOpticalRoute { pairKey: string; geometry: OpticalRouteGeometry; }
export interface RouteSessionPreview {
  id: string; shapes: Shape[]; ports: ResolvedPort[]; routes: PlannedRoute[];
  profiles: RouteMaterialProfile[]; materials: RouteMaterialResult[]; warnings: string[];
  obstacleCount: number; maximumApproximationErrorNm: number;
  plannerStats: RoutePlannerStats; validationWork: number;
  ownerCellId: number; ownerCellKey: string;
  /** States the actual electrical polyline or optical continuous curve length;
   * optical sampled chord length is reported separately in its geometry. */
  lengthDefinition: string;
  opticalRoutes?: RouteSessionOpticalRoute[];
}
export interface RouteSessionResult { ok: boolean; message: string; preview?: RouteSessionPreview; }
