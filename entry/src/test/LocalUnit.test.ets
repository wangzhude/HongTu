import { describe, beforeEach, it, expect } from '@ohos/hypium';
import { snapService } from '../main/ets/services/SnapService';
import { Shape, ShapeType, Point, getShapeBounds, packShapesCoordinates, nativeShapesToShapes, hasKeyholeBridgeEdges, extractKeyholeCleanLoops } from '../main/ets/models/GdsiiData';
import { cleanDbuNm } from '../main/ets/services/PrecisionService';
import { GdsByteWriter } from '../main/ets/services/LayoutExportService';
import { formatZoomPercent, worldToScreenPx, screenToWorldPx } from '../main/ets/common/constants';
import { worldViewportFromCamera } from '../main/ets/services/HierarchyExpandService';
import { LayerGroup } from '../main/ets/common/types';
import type { LayoutPort, LayoutCrossSection, LayoutContextRecord } from '../main/ets/models/LayoutPort';
import type { LayoutPropRecord, NativeShape } from '../main/cpp/types/libhongtu/Index';
import { EditService, editService, EditStructureState } from '../main/ets/services/EditService';
import { advEditService } from '../main/ets/services/AdvancedEditService';
import { flattenPreviewService } from '../main/ets/services/FlattenPreviewService';
import { legacyDocumentPrecision } from '../main/ets/services/PrecisionService';
import { cloneShapeArray, markImmutablePointArray } from '../main/ets/common/CloneUtils';
import {
  computeShapeDigest,
  IncrementalDocumentSnapshotCache,
  IncrementalSnapshotStats
} from '../main/ets/common/CloneUtils';
import {
  PropertyCellOption,
  prepareShapeProperty,
  validatePropertyHierarchy
} from '../main/ets/services/ShapePropertyService';
import { WorkspaceDocument, WorkspaceService } from '../main/ets/services/WorkspaceService';
import {
  PYTHON_VERIFY_MAX_RESPONSE_BYTES,
  PYTHON_ARTIFACT_ID_REGEX,
  normalizePythonArtifactId,
  validatePythonBridgeEndpoint,
  normalizePythonBridgeCaPath
} from '../main/ets/services/PythonBridgeService';

function buildMinimalWorkspaceDocument(cellNames: string[], shapes: Shape[]): WorkspaceDocument {
  const emptyCellProps: LayoutPropRecord[][] = cellNames.map((): LayoutPropRecord[] => []);
  const emptyCellContexts: LayoutContextRecord[][] = cellNames.map((): LayoutContextRecord[] => []);
  const keys: string[] = cellNames.map((_name: string, index: number): string => `cell-key-${index}`);
  const emptyPorts: LayoutPort[] = [];
  const emptyCrossSections: LayoutCrossSection[] = [];
  const emptyLayoutContexts: LayoutContextRecord[] = [];
  return {
    version: 2,
    id: 'doc-unit-test-1',
    title: 'UnitTestLayout',
    sourcePath: '',
    saveUri: '',
    projectUri: '',
    libName: 'UNIT_LIB',
    topCellName: cellNames[0],
    topCellId: 0,
    cellNames: cellNames,
    cellKeys: keys,
    ports: emptyPorts,
    crossSections: emptyCrossSections,
    layoutContextRecords: emptyLayoutContexts,
    cellContextRecords: emptyCellContexts,
    cellProperties: emptyCellProps,
    libProperties: [],
    shapes: shapes,
    layers: [
      {
        layerNumber: 1,
        datatype: 0,
        englishName: 'METAL1',
        chineseName: '金属1',
        color: '#3B82F6',
        visible: true,
        elementCount: shapes.length,
        group: LayerGroup.INTERCONNECT
      }
    ],
    userUnits: 0.001,
    physicalUnits: 1e-9,
    dirty: false,
    viewMode: 'edit',
    cellStack: [0],
    selectedIds: [],
    zoom: 1,
    offsetX: 0,
    offsetY: 0,
    hierarchyDepth: 16,
    gridSize: 10,
    rulers: [],
    pcells: [],
    technologyId: '',
    revision: 1,
    updatedAt: 1700000000000
  };
}

export default function localUnitTest(): void {
  describe('HongTuEditUndoRedoSuite', (): void => {
    let editor: EditService = new EditService();

    beforeEach((): void => {
      editor = new EditService();
    });

    it('restores_geometry_and_clean_marker_across_undo_redo_chain', 0, (): void => {
      expect(editor.canUndo()).assertFalse();
      expect(editor.isDirty()).assertFalse();

      const rect: Shape = editor.createRect(1, 0, 0, 200, 100, 0);
      expect(editor.getShapeCount()).assertEqual(1);
      expect(editor.canUndo()).assertTrue();
      expect(editor.isDirty()).assertTrue();

      editor.markClean();
      expect(editor.isDirty()).assertFalse();

      const moved: boolean = editor.moveShape(rect.id, 50, -30);
      expect(moved).assertTrue();
      expect(editor.isDirty()).assertTrue();
      const movedBounds = getShapeBounds(editor.getShapes()[0]);
      expect(movedBounds.minX).assertEqual(50);
      expect(movedBounds.minY).assertEqual(-30);

      const deleted: boolean = editor.deleteShape(rect.id);
      expect(deleted).assertTrue();
      expect(editor.getShapeCount()).assertEqual(0);

      expect(editor.undo()).assertTrue();
      expect(editor.getShapeCount()).assertEqual(1);
      expect(getShapeBounds(editor.getShapes()[0]).minX).assertEqual(50);

      expect(editor.undo()).assertTrue();
      expect(getShapeBounds(editor.getShapes()[0]).minX).assertEqual(0);
      expect(editor.isDirty()).assertFalse();

      expect(editor.redo()).assertTrue();
      expect(getShapeBounds(editor.getShapes()[0]).minX).assertEqual(50);
      expect(editor.isDirty()).assertTrue();
    });

    it('commits_batch_transaction_as_single_atomic_undo_step', 0, (): void => {
      editor.beginBatch();
      const r1: Shape = editor.createRect(1, 0, 0, 100, 100, 0);
      const r2: Shape = editor.createRect(2, 200, 0, 300, 100, 0);
      editor.moveShape(r1.id, 10, 20);
      editor.endBatch();

      expect(editor.isTransactionOpen()).assertFalse();
      expect(editor.getShapeCount()).assertEqual(2);
      expect(editor.undoStepCount()).assertEqual(1);

      expect(editor.undo()).assertTrue();
      expect(editor.getShapeCount()).assertEqual(0);
      expect(editor.canRedo()).assertTrue();

      expect(editor.redo()).assertTrue();
      expect(editor.getShapeCount()).assertEqual(2);
      expect(r2.layerNumber).assertEqual(2);
    });
  });

  describe('HongTuIncrementalSnapshotLargeCoordinateSuite', (): void => {
    it('distinguishes_wafer_scale_large_coordinates_without_digest_collision', 0, (): void => {
      const basePoints: Point[] = [
        { x: 150000000, y: -150000000 },
        { x: 150005000, y: -149998000 }
      ];
      const shiftedPoints: Point[] = [
        { x: 150000001, y: -150000000 },
        { x: 150005000, y: -149998000 }
      ];
      const highRangePoints: Point[] = [
        { x: 4294968, y: -4294968 },
        { x: 4295968, y: -4293968 }
      ];
      const s1: Shape = {
        id: 101,
        type: ShapeType.RECT,
        layerNumber: 68,
        datatype: 20,
        points: basePoints,
        selected: false
      };
      const s2: Shape = {
        id: 101,
        type: ShapeType.RECT,
        layerNumber: 68,
        datatype: 20,
        points: shiftedPoints,
        selected: false
      };
      const s3: Shape = {
        id: 101,
        type: ShapeType.RECT,
        layerNumber: 68,
        datatype: 20,
        points: highRangePoints,
        selected: false
      };

      const d1: number = computeShapeDigest(s1);
      const d2: number = computeShapeDigest(s2);
      const d3: number = computeShapeDigest(s3);
      expect(d1 === computeShapeDigest(s1)).assertTrue();
      expect(d1 !== d2).assertTrue();
      expect(d1 !== d3).assertTrue();
      expect(d2 !== d3).assertTrue();
    });

    it('reuses_unmodified_shapes_and_reclones_mutated_large_coordinate_shapes', 0, (): void => {
      const cache: IncrementalDocumentSnapshotCache = new IncrementalDocumentSnapshotCache();
      const shapes: Shape[] = [
        {
          id: 1,
          type: ShapeType.RECT,
          layerNumber: 1,
          datatype: 0,
          points: [{ x: 120000000, y: 80000000 }, { x: 120001000, y: 80000500 }],
          selected: false
        },
        {
          id: 2,
          type: ShapeType.RECT,
          layerNumber: 2,
          datatype: 0,
          points: [{ x: -90000000, y: 45000000 }, { x: -89999000, y: 45001000 }],
          selected: false
        }
      ];

      const snap1: Shape[] = cache.captureReadOnlyShapes('doc-wafer', shapes);
      const stats1: IncrementalSnapshotStats = cache.stats();
      expect(stats1.misses).assertEqual(2);
      expect(stats1.hits).assertEqual(0);

      shapes[1].points[1].x = -89998999;
      const snap2: Shape[] = cache.captureReadOnlyShapes('doc-wafer', shapes);
      const stats2: IncrementalSnapshotStats = cache.stats();
      expect(stats2.hits).assertEqual(1);
      expect(stats2.misses).assertEqual(3);
      expect(snap2[0] === snap1[0]).assertTrue();
      expect(snap2[1] === snap1[1]).assertFalse();
      expect(snap1[1].points[1].x).assertEqual(-89999000);
      expect(snap2[1].points[1].x).assertEqual(-89998999);
    });
  });

  describe('HongTuCrossTabInstanceValidationSuite', (): void => {
    it('rejects_foreign_tab_instance_cell_id_and_cyclic_cell_references', 0, (): void => {
      const targetTabCells: PropertyCellOption[] = [
        { id: 0, name: 'TOP_B' },
        { id: 1, name: 'CHILD_B' }
      ];
      const foreignInstance: Shape = {
        id: 10,
        type: ShapeType.INSTANCE,
        layerNumber: 0,
        datatype: 0,
        points: [{ x: 0, y: 0 }],
        selected: false,
        ownerCellId: 0,
        cellId: 1,
        cellName: 'CHILD_B'
      };
      const existingShapes: Shape[] = [
        foreignInstance,
        {
          id: 11,
          type: ShapeType.INSTANCE,
          layerNumber: 0,
          datatype: 0,
          points: [{ x: 100, y: 0 }],
          selected: false,
          ownerCellId: 1,
          cellId: 0,
          cellName: 'TOP_B'
        }
      ];

      // Foreign cellId=5 from another tab does not exist in target tab (0..1)
      const missingErr: string = prepareShapeProperty(
        foreignInstance, 'cellId', '5', targetTabCells, [foreignInstance], 0
      );
      expect(missingErr).assertEqual('引用 Cell 不存在');

      // Cyclic hierarchy TOP_B (0) -> CHILD_B (1) -> TOP_B (0) must be rejected
      const cycleHierarchyErr: string = validatePropertyHierarchy(existingShapes, 0);
      expect(cycleHierarchyErr).assertEqual('修改会形成循环 Cell 引用');

      const editor: EditService = new EditService();
      expect(editor.createShapeCopies(existingShapes).length).assertEqual(0);

      // WorkspaceService.parseDocument accepts local INSTANCE (cellId=1) and rejects foreign out-of-bounds cellId=4
      const ws: WorkspaceService = new WorkspaceService();
      const validDoc: WorkspaceDocument = buildMinimalWorkspaceDocument(['TOP_B', 'CHILD_B'], [foreignInstance]);
      const parsedValid: WorkspaceDocument = ws.parseDocument(JSON.stringify(validDoc));
      expect(parsedValid.shapes.length).assertEqual(1);

      const badInstance: Shape = {
        id: 1,
        type: ShapeType.INSTANCE,
        layerNumber: 0,
        datatype: 0,
        points: [{ x: 0, y: 0 }],
        selected: false,
        ownerCellId: 0,
        cellId: 4,
        cellName: 'TAB_A_ONLY_CELL'
      };
      const invalidDoc: WorkspaceDocument = buildMinimalWorkspaceDocument(['TOP_B', 'CHILD_B'], [badInstance]);
      let threwInvalidCell: boolean = false;
      try {
        ws.parseDocument(JSON.stringify(invalidDoc));
      } catch (err) {
        threwInvalidCell = String(err).indexOf('实例引用 Cell 无效') >= 0;
      }
      expect(threwInvalidCell).assertTrue();
    });
  });

  describe('HongTuPythonBridgeContractSuite', (): void => {
    it('aligns_verify_budget_artifact_id_normalization_and_https_endpoints', 0, (): void => {
      expect(PYTHON_VERIFY_MAX_RESPONSE_BYTES).assertEqual(16 * 1024 * 1024);
      expect(PYTHON_ARTIFACT_ID_REGEX.source).assertEqual(
        '^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
      );

      const hex32: string = '0123456789abcdef0123456789abcdef';
      const uuid36: string = '01234567-89ab-cdef-0123-456789abcdef';
      expect(normalizePythonArtifactId(hex32)).assertEqual(hex32);
      expect(normalizePythonArtifactId(uuid36)).assertEqual(hex32);

      const badIds: string[] = [
        '0123456789ABCDEF0123456789ABCDEF',
        '../0123456789abcdef0123456789abcd',
        '01234567-89ab-cdef-0123-456789abcde',
        ''
      ];
      for (let i: number = 0; i < badIds.length; i++) {
        let rejected: boolean = false;
        try {
          normalizePythonArtifactId(badIds[i]);
        } catch (_) {
          rejected = true;
        }
        expect(rejected).assertTrue();
      }

      expect(validatePythonBridgeEndpoint('http://127.0.0.1:7865/')).assertEqual('http://127.0.0.1:7865');
      expect(validatePythonBridgeEndpoint('http://localhost:7865')).assertEqual('http://localhost:7865');
      expect(validatePythonBridgeEndpoint('https://192.168.1.18:7865/')).assertEqual('https://192.168.1.18:7865');
      expect(validatePythonBridgeEndpoint('https://companion.hongtu.local:8443')).assertEqual(
        'https://companion.hongtu.local:8443'
      );

      let lanHttpRejected: boolean = false;
      try {
        validatePythonBridgeEndpoint('http://192.168.1.18:7865');
      } catch (_) {
        lanHttpRejected = true;
      }
      expect(lanHttpRejected).assertTrue();

      expect(normalizePythonBridgeCaPath('  ')).assertUndefined();
      expect(normalizePythonBridgeCaPath('/data/storage/el2/base/files/bridge-ca.pem')).assertEqual(
        '/data/storage/el2/base/files/bridge-ca.pem'
      );
      let traversalRejected: boolean = false;
      try {
        normalizePythonBridgeCaPath('/data/storage/../etc/passwd.pem');
      } catch (_) {
        traversalRejected = true;
      }
      expect(traversalRejected).assertTrue();
    });
  });

  describe('HongTuFlattenNewlyGroupedCellSuite', (): void => {
    it('flattens_newly_grouped_cell_instance_without_key_order_mismatch', 0, (): void => {
      const initialShapes: Shape[] = [
        {
          id: 1,
          type: ShapeType.RECT,
          layerNumber: 6,
          datatype: 0,
          ownerCellId: 0,
          points: [{ x: 0, y: 0 }, { x: 120, y: 200 }],
          selected: true
        },
        {
          id: 2,
          type: ShapeType.RECT,
          layerNumber: 6,
          datatype: 0,
          ownerCellId: 0,
          points: [{ x: 40, y: 40 }, { x: 160, y: 240 }],
          selected: true
        }
      ];
      let structure: EditStructureState = {
        cellNames: ['TOP'],
        cellProperties: [[]],
        libProperties: [],
        topCellId: 0,
        cellStack: [0],
        cellKeys: ['cell-key-0'],
        ports: [],
        crossSections: [],
        layoutContextRecords: [],
        cellContextRecords: [[]],
        precision: legacyDocumentPrecision(1e-9, 10)
      };
      editService.setStructureStateProvider((): EditStructureState => structure);
      editService.setStructureRestoreAction((nextState: EditStructureState): void => { structure = nextState; });
      editService.setActiveDocumentIdentity('doc-unit-test-1');
      editService.setTopCellId(0);
      try {
        editService.setShapes(initialShapes);
        editService.selectMultiple([1, 2]);

        const created = advEditService.makeCellFromSelection('CELL_2', structure, 6, 0);
        expect(created !== null).assertTrue();
        expect(structure.cellNames.length).assertEqual(2);

        const selectedInstances: Shape[] = editService.getSelectedShapes().filter(
          (item: Shape): boolean => item.type === ShapeType.INSTANCE
        );
        expect(selectedInstances.length).assertEqual(1);
        const instanceId: number = selectedInstances[0].id;

        const doc: WorkspaceDocument = buildMinimalWorkspaceDocument(
          structure.cellNames.slice(),
          editService.getShapes()
        );
        doc.cellKeys = (structure.cellKeys ?? []).slice();
        doc.cellProperties = structure.cellProperties.slice();
        doc.cellContextRecords = (structure.cellContextRecords ?? []).slice();
        doc.selectedIds = [instanceId];

        expect(JSON.stringify(cloneShapeArray(doc.shapes, true))).assertEqual(
          JSON.stringify(cloneShapeArray(editService.getShapes(), true))
        );
        const prepared = flattenPreviewService.prepare(doc, [instanceId]);
        expect(prepared.ok).assertTrue();
        expect(prepared.preview !== undefined).assertTrue();
        expect(doc.precision === undefined).assertTrue();
        structure.precision = legacyDocumentPrecision(1e-9, 20);
        const rejected = flattenPreviewService.apply(prepared.preview!, doc, structure);
        expect(rejected.ok).assertFalse();
        structure.precision = legacyDocumentPrecision(1e-9, 10);
        const applied = flattenPreviewService.apply(prepared.preview!, doc, structure);
        expect(applied.ok).assertTrue();
        expect(editService.getShapes().filter((shape: Shape): boolean => shape.ownerCellId === 0).length).assertEqual(2);
      } finally {
        editService.setStructureRestoreAction(null);
        editService.setStructureStateProvider(null);
        editService.setShapes([]);
        editService.setActiveDocumentIdentity('');
      }
    });
  });

  describe('HongTuLargeLayoutMemoryAndWaferZoomSuite', (): void => {
    it('packs_and_hydrates_large_coordinate_buffers_with_cow_point_sharing', 0, (): void => {
      const sourceShapes: Shape[] = [];
      for (let i = 0; i < 150; i++) {
        const pts: Point[] = [];
        for (let k = 0; k < 64; k++) {
          pts.push({ x: i * 1000 + k * 10, y: -i * 500 + k * 5 });
        }
        sourceShapes.push({
          id: i + 1,
          type: ShapeType.POLYGON,
          layerNumber: 4,
          datatype: 0,
          points: pts,
          selected: false,
          ownerCellId: 0
        });
      }
      const packed = packShapesCoordinates(sourceShapes, 8192);
      expect(packed.totalPoints).assertEqual(9600);
      expect(packed.packedCoords !== undefined).assertTrue();

      const hydrated = nativeShapesToShapes(
        sourceShapes.map((s: Shape): NativeShape => ({
          id: s.id,
          type: 'polygon',
          layerNumber: s.layerNumber,
          datatype: s.datatype,
          points: [],
          pathWidth: 0,
          text: '',
          cellName: '',
          ownerCellId: 0,
          cellId: -1,
          rotation: 0,
          mirror: 0,
          magnification: 1
        })),
        packed.packedCoords,
        packed.shapePointOffsets,
        packed.shapePointCounts
      );
      expect(hydrated.length).assertEqual(150);
      expect(hydrated[149].points[63].x).assertEqual(149 * 1000 + 630);
      // CoW immutable Point[] array sharing: zero duplicate point array allocation
      const cloned = cloneShapeArray(hydrated);
      expect(cloned[0] === hydrated[0]).assertFalse();
      expect(cloned[0].points === hydrated[0].points).assertTrue();
      const editor: EditService = new EditService();
      editor.setShapes(hydrated);
      const sharedPoints: Point[] = editor.getShapes()[0].points;
      expect(editor.updateShape(1, -1, 20, -30)).assertTrue();
      expect(editor.getShapes()[0].points[0].x).assertEqual(20);
      expect(sharedPoints[0].x).assertEqual(0);
      expect(sharedPoints[0].y).assertEqual(0);
      expect(editor.undo()).assertTrue();
      expect(editor.getShapes()[0].points[0].x).assertEqual(0);
      expect(editor.getShapes()[0].points[0].y).assertEqual(0);
    });

    it('cleans_dbu_float_noise_and_supports_full_6_inch_wafer_zoom', 0, (): void => {
      expect(cleanDbuNm(1e-7)).assertEqual(100);
      expect(String(cleanDbuNm(1e-7))).assertEqual('100');
      expect(formatZoomPercent(0.00062)).assertEqual('0.00062%');

      const z: number = 0.0006;
      const wx: number = 82385000;
      const roundtrip: number = screenToWorldPx(worldToScreenPx(wx, z, 0), z, 0);
      expect(Math.abs(roundtrip - wx) < 1e-3).assertTrue();

      const vp = worldViewportFromCamera(1200, 900, z, 0, 151000000, 64);
      expect(vp.maxX - vp.minX > 151000000).assertTrue();
    });
  });

  describe('HongTuPcselHandDrawFixesSuite', (): void => {
    it('streams_multi_chunk_gds_records_via_uint8array_without_boxed_array_oom', 0, (): void => {
      const writer: GdsByteWriter = new GdsByteWriter();
      const pts: Point[] = [];
      for (let i = 0; i < 4096; i++) {
        pts.push({ x: -150000 + i * 75, y: 150000 - i * 50 });
      }
      // Write 6 polygons (~196 KiB > initial 64 KiB buffer) to verify dynamic Uint8Array growth & byte fidelity
      for (let k = 0; k < 6; k++) {
        writer.writePointSliceXYRecord({ type: 0x10, dataType: 0x03 }, pts, 0, pts.length, (nm: number): number => nm);
      }
      const ab: ArrayBuffer = writer.toArrayBuffer();
      expect(ab.byteLength).assertEqual(6 * (4 + 4096 * 8));
      const view: DataView = new DataView(ab);
      expect(view.getUint16(0, false)).assertEqual(4 + 4096 * 8);
      expect(view.getUint8(2)).assertEqual(0x10);
      expect(view.getUint8(3)).assertEqual(0x03);
      expect(view.getInt32(4, false)).assertEqual(-150000);
      expect(view.getInt32(8, false)).assertEqual(150000);
    });

    it('prevents_fake_breadcrumbs_and_cyclic_placements_across_multi_root_cells', 0, (): void => {
      const svc: EditService = new EditService();
      // Cell 0: PIXSMALL, Cell 1: OUTERBAND (refs 0), Cell 2: PIXLARGE (unreferenced leaf), Cell 3: zhengban_1 (top, refs 1)
      svc.setTopCellId(3);
      svc.adoptShapes([
        { id: 1, type: ShapeType.POLYGON, layerNumber: 4, datatype: 0, ownerCellId: 0, selected: false,
          points: [{ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 100, y: 100 }] },
        { id: 2, type: ShapeType.INSTANCE, layerNumber: 0, datatype: 0, ownerCellId: 1, cellId: 0, cellName: 'PIXSMALL',
          selected: false, points: [{ x: 0, y: 0 }] },
        { id: 3, type: ShapeType.INSTANCE, layerNumber: 0, datatype: 0, ownerCellId: 3, cellId: 1, cellName: 'OUTERBAND',
          selected: false, points: [{ x: 0, y: 0 }] },
        { id: 4, type: ShapeType.POLYGON, layerNumber: 4, datatype: 0, ownerCellId: 2, selected: false,
          points: [{ x: -150, y: -150 }, { x: 150, y: -150 }, { x: 150, y: 150 }] }
      ]);

      // Reachability & cycle detection
      expect(svc.canReachCell(3, 1)).assertTrue();
      expect(svc.canReachCell(3, 0)).assertTrue();
      expect(svc.canReachCell(3, 2)).assertFalse();
      expect(svc.wouldCreateCellCycle(3, 3)).assertTrue();
      expect(svc.wouldCreateCellCycle(0, 1)).assertTrue();
      expect(svc.wouldCreateCellCycle(0, 3)).assertTrue();
      expect(svc.wouldCreateCellCycle(3, 2)).assertFalse();

      // Reachable child PIXSMALL gets [3, 0] breadcrumb; unreferenced PIXLARGE gets clean [2] without fake breadcrumb!
      expect(svc.navigateToCellDefinition(0)).assertTrue();
      expect(JSON.stringify(svc.getCurrentCellStack())).assertEqual('[3,0]');
      expect(svc.navigateToCellDefinition(2)).assertTrue();
      expect(JSON.stringify(svc.getCurrentCellStack())).assertEqual('[2]');
      expect(svc.navigateToCellDefinition(3)).assertTrue();
      expect(JSON.stringify(svc.getCurrentCellStack())).assertEqual('[3]');
    });

    it('extracts_clean_loops_from_keyhole_bridged_polygon_and_caches_immutable_bounds', 0, (): void => {
      const keyholePts: Point[] = [
        { x: -1500, y: -1500 },
        { x: 1500, y: -1500 },
        { x: 1500, y: 0 },
        { x: 500, y: 0 },
        { x: 0, y: -500 },
        { x: -500, y: 0 },
        { x: 0, y: 500 },
        { x: 500, y: 0 },
        { x: 1500, y: 0 },
        { x: 1500, y: 1500 },
        { x: -1500, y: 1500 }
      ];
      expect(hasKeyholeBridgeEdges(keyholePts)).assertTrue();
      const loops: Point[][] = extractKeyholeCleanLoops(keyholePts);
      expect(loops.length).assertEqual(2);
      expect(loops[0].length + loops[1].length).assertEqual(9);

      const simplePts: Point[] = [{ x: 0, y: 0 }, { x: 200, y: 0 }, { x: 200, y: 200 }, { x: 0, y: 200 }];
      expect(hasKeyholeBridgeEdges(simplePts)).assertFalse();
      expect(extractKeyholeCleanLoops(simplePts).length).assertEqual(1);

      const keyholeShape: Shape = { id: 10, type: ShapeType.POLYGON, layerNumber: 4, datatype: 0, points: keyholePts, selected: false };
      expect(advEditService.isVertexEditable(keyholeShape)).assertFalse();
      const simpleShape: Shape = { id: 11, type: ShapeType.POLYGON, layerNumber: 4, datatype: 0, points: simplePts, selected: false };
      expect(advEditService.isVertexEditable(simpleShape)).assertTrue();

      const packed = packShapesCoordinates([keyholeShape]);
      const unpacked = nativeShapesToShapes(
        [{ id: 10, type: 'polygon', layerNumber: 4, datatype: 0, points: [], pathWidth: 0, text: '', cellName: '', ownerCellId: 0, cellId: -1, rotation: 0, mirror: 0, magnification: 1 }],
        packed.packedCoords, packed.pointOffsets, packed.pointCounts
      );
      expect(unpacked.length).assertEqual(1);
      const b1 = getShapeBounds(unpacked[0]);
      expect(b1.minX).assertEqual(-1500);
      expect(b1.maxX).assertEqual(1500);
      b1.minX = 999999;
      const b2 = getShapeBounds(unpacked[0]);
      expect(b2.minX).assertEqual(-1500);
      expect(b2.maxY).assertEqual(1500);
    });

    it('accelerates_million_vertex_immutable_snapshot_and_dense_polygon_snap', 0, (): void => {
      const cache: IncrementalDocumentSnapshotCache = new IncrementalDocumentSnapshotCache();
      const ringPts: Point[] = [];
      for (let i = 0; i < 4096; i++) {
        const ang: number = (2 * Math.PI * i) / 4096;
        ringPts.push({ x: Math.round(Math.cos(ang) * 500000), y: Math.round(Math.sin(ang) * 500000) });
      }
      markImmutablePointArray(ringPts);
      const bigShapes: Shape[] = [];
      for (let s = 0; s < 64; s++) {
        bigShapes.push({
          id: s + 1,
          type: ShapeType.POLYGON,
          layerNumber: 1,
          datatype: 0,
          points: ringPts,
          selected: false,
          ownerCellId: 0
        });
      }
      const snapA: Shape[] = cache.captureReadOnlyShapes('bjut-doc', bigShapes);
      const snapB: Shape[] = cache.captureReadOnlyShapes('bjut-doc', bigShapes);
      expect(snapA.length).assertEqual(64);
      expect(snapB[0] === snapA[0]).assertTrue();
      expect(snapA[0].points === ringPts).assertTrue();

      const snapIdx = snapService.ensureSpatialIndex('bjut-ring-test', [bigShapes[0]]);
      const rich = snapService.snapRich(500005, 2, snapIdx, true, 50, ['顶点', '中点', '边'], false, 0, false, 0);
      expect(rich.snappedGeometry).assertTrue();
      expect(Math.abs(rich.point.x - 500000) <= 50).assertTrue();
    });
  });
}
