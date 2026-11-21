import type { Point, Shape } from './GdsiiData';
import type { LayoutCrossSection, ResolvedPort } from './LayoutPort';
import type { TechnologyPackage } from '../common/technologyPackage';

/** Signed offsets are along the port's local +Y axis; the full resolved frame applies. */
export interface RouteMaterialStrip {
  id: string; layerNumber: number; datatype: number; widthNm: number; offsetNm: number;
}
export interface RouteMaterialDescriptor {
  schema: 'hongtu-route-material/v1'; primaryStripId: string; strips: RouteMaterialStrip[];
  minimumBendRadiusNm?: number;
}
export interface RouteLayerPair { layerNumber: number; datatype: number; }
export interface RouteTaperRule {
  schema: 'hongtu-route-transition/v1'; kind: 'linear-taper';
  /** Linear signed-edge interpolation across the whole centerline arc length. */
  minimumLengthNm: number; maximumEdgeSlope: number;
}
export interface RouteViaRule {
  schema: 'hongtu-route-transition/v1'; kind: 'via'; technologyId: string; technologyVersion: string;
  lowerLayerNumber: number; lowerDatatype: number; upperLayerNumber: number; upperDatatype: number;
  cutLayerNumber: number; cutDatatype: number;
  /** Physical arc-length station from the start port; cuts and pads use world X/Y axes. */
  stationNm: number; cutWidthNm: number; cutHeightNm: number;
  columns: number; rows: number; gapXNm: number; gapYNm: number;
  lowerEnclosureXNm: number; lowerEnclosureYNm: number;
  upperEnclosureXNm: number; upperEnclosureYNm: number;
  /** Required only when continuous auxiliary strips differ between endpoint frames. */
  auxiliaryTaperMinimumLengthNm?: number; auxiliaryMaximumEdgeSlope?: number;
}
export type RouteTransitionRule = RouteTaperRule | RouteViaRule;
export interface RouteMaterialBudget {
  maximumCenterlinePoints?: number; maximumMaterials?: number; maximumShapes?: number;
  maximumVertices?: number; maximumWork?: number; maximumMiterRatio?: number;
}
export interface RouteMaterialInspectRequest {
  start: ResolvedPort; end: ResolvedPort; dbuNm: number;
  startCrossSection?: LayoutCrossSection; endCrossSection?: LayoutCrossSection;
  /** Explicit descriptor overrides require consistency with any referenced CrossSection. */
  descriptorJson?: string; endDescriptorJson?: string; transitionRuleJson?: string;
  technology?: TechnologyPackage; budget?: RouteMaterialBudget;
  /** Optical curves may retain continuous transformed port centers only with
   * a separately explicit real DBU cap tolerance policy in the caller. */
  portCoordinatePolicy?: 'strict' | 'continuous-for-optical';
}
export interface RouteMaterialRequest extends RouteMaterialInspectRequest {
  centerlineNm: Point[]; ownerCellId: number; firstShapeId: number;
  /** A sampled curve is already a physical polyline; this layer does not invent a bend. */
  bendModel?: 'miter-polyline' | 'sampled-curve';
  /** All endpoints/caps stay exact; only non-cap material vertices may be quantized. */
  coordinatePolicy?: 'strict' | 'quantize-interior';
}
export interface RouteMaterialBand {
  id: string; layerNumber: number; datatype: number; minimumNm: number; maximumNm: number;
}
export interface RouteMaterialProfile {
  descriptorSchemas: string[]; transitionKind: 'uniform' | 'linear-taper' | 'via';
  startBands: RouteMaterialBand[]; endBands: RouteMaterialBand[];
  primaryStripId: string; startPrimaryLayer: RouteLayerPair; endPrimaryLayer: RouteLayerPair;
  startWidthNm: number; endWidthNm: number; maximumPrimaryWidthNm: number;
  envelopeMinimumNm: number; envelopeMaximumNm: number; obstacleEnvelopeWidthNm: number;
  routeLayerPairs: RouteLayerPair[]; minimumBendRadiusNm: number; viaPadRadiusNm: number;
}
export interface RouteMaterialCap {
  portId: string; centerNm: Point; lowerEdgeNm: Point; upperEdgeNm: Point;
  layerNumber: number; datatype: number; expectedWidthNm: number; actualWidthNm: number;
}
export interface RouteMaterialResult {
  shapes: Shape[]; profile: RouteMaterialProfile; endpointCaps: RouteMaterialCap[];
  centerlineLengthNm: number; quantizedInteriorVertices: number; maximumQuantizationErrorNm: number;
  transitionRule?: RouteTransitionRule; materialShapeIds: number[]; cutShapeIds: number[]; padShapeIds: number[];
  warnings: string[]; workUsed: number;
}
/** Actual resolved executable enclosure/transition sources, including foreign
 * CrossSection bbox semantics. Consumers must not reconstruct guessed JSON. */
export interface RouteMaterialBboxSection { layerNumber: number; datatype: number; offsetNm: number; }
export interface RouteMaterialExecution {
  profile: RouteMaterialProfile; bboxSections: RouteMaterialBboxSection[]; transitionRule?: RouteTransitionRule;
}
