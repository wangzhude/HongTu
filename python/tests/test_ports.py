"""Real KLayout worker + authenticated HTTP/job checks for typed port transport."""
import base64
import copy
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import unittest
import uuid

import klayout.db as db
from hongtu import bridge
from hongtu.jobs import JobRegistry
from hongtu.policy import PolicyError, validate_script
from hongtu.ports import (CELL_KEY, CELL_PORTS, CROSS_SECTIONS, attach_context,
                          capture_input_context, prepare_ports, preserve_input_context,
                          read_gds_context, _metadata_value_budget, add_port, update_port, get_ports)
from hongtu.worker import execute


CREATE_SCRIPT = """from hongtu import *
layout=Layout()
layout.dbu=.001
top=layout.create_cell('PORT_TOP')
child=layout.create_cell('PORT_CHILD')
child.shapes(layout.layer(7,3)).insert(Box(0,-250,1000,250))
top.insert(CellInstArray(child.cell_index(),ICplxTrans(1.5,37,True,1000,-2000),Vector(3000,600),Vector(-400,2000),3,2))
p=add_port(child,'西端口',(0,0),500,180,7,3,info={'nested':[1,2.5,True,{'text':'中文'}]})
q=add_port(child,'angle37',(123,-456),500,37,7,3,port_type='user-mode',frame_mirror=True,frame_magnification=1.2)
update_port(child,p['id'],{'centerNm':{'x':-100,'y':0}})
temporary=add_port(top,'temporary',(0,0),10,0,7,3)
remove_port(top,temporary['id'])
print(get_ports(child))
"""

PORT_ONLY_SCRIPT = """import hongtu as db
layout=db.Layout()
layout.dbu=.001
cell=layout.create_cell('PORT_ONLY')
db.add_port(cell,'端口独立定义',(123,-456),500,37,7,3,
            frame_mirror=True,frame_magnification=1.2,info={'onlyPorts':True})
"""


def layout_input(layout):
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder, 'source.gds')
        options = db.SaveLayoutOptions()
        options.gds2_write_cell_properties = True
        options.gds2_write_file_properties = True
        layout.write(str(path), options)
        return base64.b64encode(path.read_bytes()).decode('ascii')


def read_result(result):
    with tempfile.TemporaryDirectory() as folder:
        path = Path(folder, 'result.gds')
        path.write_bytes(base64.b64decode(result['gdsBase64']))
        layout = db.Layout()
        layout.read(str(path))
        return layout


def foreign_layout(width=500):
    layout = db.Layout(); layout.dbu = .001
    cell = layout.create_cell('FOREIGN')
    cell.shapes(layout.layer(7, 3)).insert(db.Box(0, 0, 12000, 500))
    layout.add_meta_info(db.LayoutMetaInfo('kfactory:settings:meta_format', 'v3', '', True))
    layout.add_meta_info(db.LayoutMetaInfo('kfactory:settings:version', '3.0.4', '', True))
    layout.add_meta_info(db.LayoutMetaInfo('kfactory:settings:klayout_version', '0.30.12', '', True))
    layout.add_meta_info(db.LayoutMetaInfo('kfactory:cross_section:xs', {'width': width, 'layer_enclosure': 'enc'}, '', True))
    layout.add_meta_info(db.LayoutMetaInfo('kfactory:layer_enclosure:enc', {'name': 'enc', 'main_layer': db.LayerInfo(7, 3), 'sections': []}, '', True))
    for index in range(12):
        cell.add_meta_info(db.LayoutMetaInfo(f'kfactory:ports:{index}', {
            'name': f'p{index}', 'cross_section': 'xs', 'trans': db.Trans(index % 4, index % 2 == 1, index * 1000, 250),
            'port_type': 'electrical', 'info': {'sourceIndex': index}, 'future': {'keep': True}}, '', True))
    cell.add_meta_info(db.LayoutMetaInfo('kfactory:pins:0', {'name': 'pin', 'pin_type': 'electrical', 'ports': [10, 2], 'info': {}}, '', True))
    return layout


def large_owned_layout():
    """A real single-Cell table under 8 MiB, with 300009 JSON value nodes."""
    layout = db.Layout(); layout.dbu = .001
    cell = layout.create_cell('LARGE_PORTS')
    cell.shapes(layout.layer(7, 3)).insert(db.Box(0, 0, 1000, 500))
    key = 'large-cell-stable-key'
    cell.add_meta_info(db.LayoutMetaInfo(CELL_KEY, key, '', True))
    definition = {'schemaVersion': 1, 'kind': 'symmetric', 'widthNm': 500, 'layerNumber': 7,
                  'datatype': 3, 'enclosure': {'name': '', 'sections': [], 'bboxSections': []}}
    sections = [{'key': 'shared-xs', 'version': 1, 'name': 'shared-xs',
                 'definitionJson': json.dumps(definition, separators=(',', ':'))}]
    layout.add_meta_info(db.LayoutMetaInfo(CROSS_SECTIONS,
        json.dumps({'schemaVersion': 1, 'crossSections': sections}, separators=(',', ':')), '', True))
    ports = [{'id': 'large-port-' + str(i), 'ownerCellId': 0, 'ownerCellKey': key,
        'name': 'p' + str(i), 'centerNm': {'x': 0, 'y': 0}, 'orientationDeg': 0, 'widthNm': 500,
        'layerNumber': 7, 'datatype': 3, 'portType': 'optical', 'frameMirror': False,
        'frameMagnification': 1, 'infoJson': '{}', 'crossSectionKey': 'shared-xs',
        'crossSectionVersion': 1} for i in range(16667)]
    body = json.dumps({'schemaVersion': 1, 'ports': ports}, separators=(',', ':'))
    assert len(body.encode('utf8')) < 8 * 1024 * 1024
    cell.add_meta_info(db.LayoutMetaInfo(CELL_PORTS, body, '', True))
    return layout


class WorkerPorts(unittest.TestCase):
    def run_worker(self, payload):
        with tempfile.TemporaryDirectory() as folder:
            return execute(payload, folder)

    def test_known_metadata_node_depth_budget_matches_native_before_publish(self):
        # Root/value nodes, not characters or object-key text. TL keys consume
        # an additional node while JSON keys do not; string JSON is atomic.
        legal = {'key': [0] * 299998}
        _metadata_value_budget(legal, 'JSON')  # 300000 value nodes exactly.
        with self.assertRaisesRegex(PolicyError, '300000 value-node'):
            _metadata_value_budget(legal, 'TL', variant=True)  # 300001.
        _metadata_value_budget({'key': [0] * 299997}, 'TL', variant=True)
        with self.assertRaisesRegex(PolicyError, '300000 value-node'):
            _metadata_value_budget([0] * 300000, 'JSON')
        nested = 0
        for unused in range(32):
            nested = [nested]
        _metadata_value_budget(nested, 'JSON')
        with self.assertRaisesRegex(PolicyError, 'depth 32'):
            _metadata_value_budget([nested], 'JSON')
        _metadata_value_budget(json.dumps([nested]), 'TL', variant=True)
        def nested_object(depth):
            value = 0
            for unused in range(depth):
                value = {'n': value}
            return value
        layout = db.Layout(); layout.dbu = .001
        cell = layout.create_cell('DEPTH')
        port = add_port(cell, 'depth31', (0, 0), 500, 0, 7, 3, info=nested_object(31))
        prepared = prepare_ports(layout)
        before = get_ports(cell)
        with self.assertRaisesRegex(PolicyError, 'depth 32'):
            add_port(cell, 'depth32', (0, 0), 500, 0, 7, 3, info=nested_object(32))
        self.assertEqual(before, get_ports(cell))
        # Same-owner foreign provenance is not needlessly restricted to 31.
        provenance = json.loads(prepared['ports'][0]['provenance'])
        provenance['future'] = nested_object(31)  # Complete object depth 32.
        update_port(cell, port['id'], {'provenance': json.dumps(provenance)})
        prepared = prepare_ports(layout)
        self.assertEqual(json.loads(prepared['ports'][0]['provenance'])['future'], provenance['future'])
        before = get_ports(cell)
        # A non-foreign object is preserved inside generated.previous. The extra
        # level must be rejected by update before committing its original Cell.
        with self.assertRaisesRegex(PolicyError, 'depth 32'):
            update_port(cell, port['id'], {'provenance': json.dumps(nested_object(32))})
        self.assertEqual(before, get_ports(cell))
        legal_info = {'items': [0] * 8190}  # Object + array + scalars = 8192.
        legal_port = add_port(cell, 'value8192', (0, 0), 500, 0, 7, 3, info=legal_info)
        update_port(cell, legal_port['id'], {'infoJson': json.dumps(legal_info)})
        prepared = prepare_ports(layout)
        self.assertEqual(json.loads(next(p for p in prepared['ports'] if p['id'] == legal_port['id'])['infoJson']), legal_info)
        before = get_ports(cell)
        with self.assertRaisesRegex(PolicyError, '8192 JSON value nodes'):
            add_port(cell, 'value8193', (0, 0), 500, 0, 7, 3, info={'items': [0] * 8191})
        with self.assertRaisesRegex(PolicyError, '8192 JSON value nodes'):
            update_port(cell, legal_port['id'], {'infoJson': json.dumps({'items': [0] * 8191})})
        self.assertEqual(before, get_ports(cell))
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(PolicyError, '300000 value-node'):
                execute({'script': 'pass', 'inputMode': 'document', 'currentCellName': 'LARGE_PORTS',
                         'documentGds': layout_input(large_owned_layout())}, folder)
            self.assertFalse(Path(folder, 'generated.gds').exists())

    def test_real_crud_foreign_frame_and_second_round_stable_identity(self):
        port_only = self.run_worker({'script': PORT_ONLY_SCRIPT})
        self.assertEqual(port_only['shapeCount'], 0)
        self.assertEqual(len(port_only['portMetadata']['ports']), 1)
        self.assertIsNotNone(read_result(port_only).cell('PORT_ONLY'))
        port_only_second = self.run_worker({'script': 'pass', 'inputMode': 'document', 'documentGds': port_only['gdsBase64']})
        self.assertEqual(port_only_second['portMetadata']['ports'], port_only['portMetadata']['ports'])
        self.assertEqual(port_only_second['layerCount'], 1)
        with self.assertRaisesRegex(PolicyError, 'drawable shapes or typed port'):
            self.run_worker({'script': "import hongtu as db\nlayout=db.Layout()\nlayout.create_cell('EMPTY')"})
        first = self.run_worker({'script': CREATE_SCRIPT})
        metadata = first['portMetadata']
        self.assertEqual(len(metadata['ports']), 2)
        self.assertEqual(metadata['diagnostics'], [])
        imported = read_result(first)
        port = next(p for p in metadata['ports'] if p['name'] == 'angle37')
        self.assertEqual(port['widthNm'], 500)
        self.assertEqual(port['frameMagnification'], 1.2)
        self.assertTrue(port['frameMirror'])
        actual = imported.cell('PORT_CHILD').meta_info_value('kfactory:ports:1')['dcplx_trans']
        self.assertEqual(actual.angle, 37)
        self.assertTrue(actual.mirror)
        self.assertAlmostEqual(actual.mag, 1.2, places=12)
        second = self.run_worker({'script': "from hongtu import *\nprint(get_ports(current_cell))",
                                  'inputMode': 'document', 'currentCellName': 'PORT_CHILD', 'documentGds': first['gdsBase64']})
        without_numeric_owner = lambda values: [dict(p, ownerCellId=0) for p in values]
        self.assertEqual(without_numeric_owner(second['portMetadata']['ports']), without_numeric_owner(metadata['ports']))
        self.assertEqual(dict(zip(second['portMetadata']['cellNames'], second['portMetadata']['cellKeys'])),
                         dict(zip(metadata['cellNames'], metadata['cellKeys'])))
        for p in second['portMetadata']['ports']:
            self.assertEqual(second['portMetadata']['cellKeys'][p['ownerCellId']], p['ownerCellKey'])
        self.assertEqual(second['portMetadata']['crossSections'], metadata['crossSections'])
        carrier = json.loads(imported.cell('PORT_CHILD').meta_info_value(CELL_PORTS))
        provenance = json.loads(carrier['ports'][0]['provenance'])
        provenance['futureSourceField'] = {'keep': ['中文', 3]}
        carrier['ports'][0]['provenance'] = json.dumps(provenance, ensure_ascii=False)
        imported.cell('PORT_CHILD').add_meta_info(db.LayoutMetaInfo(CELL_PORTS, json.dumps(carrier, ensure_ascii=False), '', True))
        third = self.run_worker({'script': 'pass', 'inputMode': 'document', 'documentGds': layout_input(imported)})
        actual = next(p for p in third['portMetadata']['ports'] if p['id'] == carrier['ports'][0]['id'])
        self.assertEqual(json.loads(actual['provenance'])['futureSourceField'], {'keep': ['中文', 3]})

    def test_foreign_v3_pins_indices_and_unknown_dict_values_preserved(self):
        source = foreign_layout()
        result = self.run_worker({'script': 'from hongtu import *\nprint(get_ports(current_cell))',
                                  'inputMode': 'document', 'currentCellName': 'FOREIGN', 'documentGds': layout_input(source)})
        self.assertEqual(len(result['portMetadata']['ports']), 12)
        imported = read_result(result)
        cell = imported.cell('FOREIGN')
        self.assertEqual(cell.meta_info_value('kfactory:pins:0')['ports'], [10, 2])
        for index in range(12):
            meta = cell.meta_info_value(f'kfactory:ports:{index}')
            self.assertEqual(meta['name'], f'p{index}')
            self.assertEqual(meta['future'], {'keep': True})
            self.assertEqual(meta['info'], {'sourceIndex': index})

    def test_pin_referenced_port_deletion_fails_before_artifact(self):
        script = "from hongtu import *\nfor p in get_ports(current_cell):\n    if p['name']=='p10':\n        remove_port(current_cell,p['id'])"
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(PolicyError, 'foreign pin'):
                execute({'script': script, 'inputMode': 'document', 'currentCellName': 'FOREIGN',
                         'documentGds': layout_input(foreign_layout())}, folder)
            self.assertFalse(Path(folder, 'generated.gds').exists())
            self.assertFalse(Path(folder, 'port-staging.gds').exists())

    def test_missing_cross_section_and_wrong_stable_owner_fail(self):
        source = foreign_layout()
        source.remove_meta_info('kfactory:cross_section:xs')
        with self.assertRaisesRegex(PolicyError, 'missing CrossSection'):
            self.run_worker({'script': 'pass', 'inputMode': 'document', 'documentGds': layout_input(source)})
        first = self.run_worker({'script': CREATE_SCRIPT})
        source = read_result(first)
        cell = source.cell('PORT_CHILD')
        carrier = json.loads(cell.meta_info_value(CELL_PORTS))
        carrier['ports'][0]['ownerCellKey'] = 'wrong-owner'
        cell.add_meta_info(db.LayoutMetaInfo(CELL_PORTS, json.dumps(carrier), '', True))
        with self.assertRaisesRegex(PolicyError, 'stable owner'):
            self.run_worker({'script': 'pass', 'inputMode': 'document', 'documentGds': layout_input(source)})
        source = read_result(first)
        cell = source.cell('PORT_CHILD')
        foreign = cell.meta_info_value('kfactory:ports:0')
        foreign['dcplx_trans'] = db.DCplxTrans(1.7, 49, False, .2, -.6)
        cell.add_meta_info(db.LayoutMetaInfo('kfactory:ports:0', foreign, '', True))
        # A persisted input marker must never impersonate a trusted API edit.
        cell.add_meta_info(db.LayoutMetaInfo('hongtu:ports_local_edit:transient', True, '', True))
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(PolicyError, 'dual port descriptions are inconsistent'):
                execute({'script': 'pass', 'inputMode': 'document', 'documentGds': layout_input(source)}, folder)
            self.assertFalse(Path(folder, 'generated.gds').exists())

    def test_width_edit_clones_descriptor_without_mutating_other_shared_ports(self):
        script = "from hongtu import *\nfor p in get_ports(current_cell):\n    if p['name']=='p0':\n        update_port(current_cell,p['id'],{'widthNm':600,'layerNumber':9,'datatype':4})"
        result = self.run_worker({'script': script, 'inputMode': 'document', 'currentCellName': 'FOREIGN',
                                 'documentGds': layout_input(foreign_layout())})
        ports = {p['name']: p for p in result['portMetadata']['ports']}
        self.assertEqual((ports['p0']['widthNm'], ports['p0']['layerNumber'], ports['p0']['datatype']), (600, 9, 4))
        self.assertEqual((ports['p1']['widthNm'], ports['p1']['layerNumber'], ports['p1']['datatype']), (500, 7, 3))
        self.assertNotEqual(ports['p0']['crossSectionKey'], ports['p1']['crossSectionKey'])

    def test_info_budget_reserved_key_typed_value_and_offgrid_fail(self):
        prefix = "from hongtu import *\nlayout=Layout()\nc=layout.create_cell('T')\nc.shapes(layout.layer(1,0)).insert(Box(0,0,10,10))\n"
        cases = ["add_port(c,'p',(0,0),10,0,1,info={'text':'x'*65536})",
                 "add_port(c,'p',(0,0),10,0,1,info={'__proto__':1})",
                 "add_port(c,'p',(0,0),10,0,1,info={'transform':Trans()})",
                 "add_port(c,'p',(0,0),10.5,0,1)"]
        for script in cases:
            with self.subTest(script=script), tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(PolicyError):
                    execute({'script': prefix + script}, folder)
                self.assertFalse(Path(folder, 'generated.gds').exists())
        with self.assertRaisesRegex(PolicyError, 'allowlist'):
            validate_script("layout.add_meta_info(LayoutMetaInfo('unrestricted',{},'',True))")

    def test_unknown_raw_bytes_order_and_rename_preserved(self):
        first = self.run_worker({'script': CREATE_SCRIPT})
        metadata = first['portMetadata']
        raw = base64.b64decode(first['gdsBase64'])
        original = {None: [b'FUTURE_LAYOUT=opaque-v4', b'\xff\xfe unknown binary'],
                    metadata['cellKeys'][1]: [b'FUTURE_CELL=keep-first', b'FUTURE_CELL2=keep-last']}
        raw = preserve_input_context(raw, original, metadata)
        result = self.run_worker({'script': "current_cell.name='RENAMED'", 'inputMode': 'document',
                                 'currentCellName': 'PORT_CHILD', 'documentGds': base64.b64encode(raw).decode('ascii')})
        groups, unused = read_gds_context(base64.b64decode(result['gdsBase64']))
        self.assertEqual(groups[None][:2], original[None])
        self.assertEqual(groups['RENAMED'][:2], original[metadata['cellKeys'][1]])
        self.assertTrue(any(r['encoding'] == 'hex' and r['value'] == 'fffe20756e6b6e6f776e2062696e617279'
                            for r in result['portMetadata']['layoutContextRecords']))

    def test_oblique_rotated_ports_grid_tolerance_and_mantissa_roundtrip(self):
        oblique_script = """from hongtu import *
import math
layout = Layout()
layout.dbu = 0.001
cell = layout.create_cell('OBLIQUE_CELL')
cell.shapes(layout.layer(7, 3)).insert(Box(0, 0, 2000, 2000))
w45 = math.hypot(354, 354)
add_port(cell, 'p45', (123.0 + 1e-12, -456.0 - 2e-12), w45, 45, 7, 3)
add_port(cell, 'p60', (250.0000000001, 500.0), 500.35, 60, 7, 3)
add_port(cell, 'p_neg', (0, 0), 800.4, -45, 7, 3)
add_port(cell, 'p_wrap', (10, 20), 500, 359.9999999999, 7, 3)
"""
        first = self.run_worker({'script': oblique_script})
        ports = {p['name']: p for p in first['portMetadata']['ports']}
        self.assertEqual(ports['p45']['widthNm'], 501)
        self.assertEqual(ports['p45']['centerNm'], {'x': 123, 'y': -456})
        self.assertEqual(ports['p60']['widthNm'], 500)
        self.assertEqual(ports['p_neg']['orientationDeg'], 315)
        self.assertEqual(ports['p_wrap']['orientationDeg'], 0)
        second = self.run_worker({'script': 'pass', 'inputMode': 'document',
                                  'currentCellName': 'OBLIQUE_CELL', 'documentGds': first['gdsBase64']})
        self.assertEqual(second['portMetadata']['ports'], first['portMetadata']['ports'])
        for bad_call in ("add_port(c,'sub',(0,0),0.2,45,1)", "add_port(c,'orth90',(0,0),10.5,90,1)"):
            with tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(PolicyError):
                    execute({'script': "from hongtu import *\nlayout=Layout()\nc=layout.create_cell('T')\nc.shapes(layout.layer(1,0)).insert(Box(0,0,10,10))\n" + bad_call}, folder)

    def test_unsupported_foreign_version_remains_explicitly_opaque(self):
        source = foreign_layout()
        source.add_meta_info(db.LayoutMetaInfo('kfactory:settings:meta_format', 'v4', '', True))
        for script in ('pass', 'from hongtu import *\nprint(get_ports(current_cell))'):
            with self.subTest(script=script):
                result = self.run_worker({'script': script, 'inputMode': 'document', 'currentCellName': 'FOREIGN',
                                         'documentGds': layout_input(source)})
                self.assertEqual(result['portMetadata']['ports'], [])
                self.assertTrue(result['portMetadata']['diagnostics'])
                imported = read_result(result)
                self.assertEqual(imported.meta_info_value('kfactory:settings:meta_format'), 'v4')
                self.assertIsNotNone(imported.cell('FOREIGN').meta_info_value('kfactory:ports:10'))


class HttpPortJobs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), bridge.Handler)
        cls.server.token = 'ports-test-token-' + 'x' * 32
        cls.server.jobs = JobRegistry()
        cls.server.job_lock = threading.Lock()
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=5)

    def request(self, method, path, body=None):
        connection = HTTPConnection('127.0.0.1', self.server.server_port, timeout=30)
        try:
            connection.request(method, path, None if body is None else json.dumps(body),
                               {'Authorization': 'Bearer ' + self.server.token, 'Content-Type': 'application/json'})
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_health_real_job_sidecar_and_worker_failure_terminal(self):
        status, health = self.request('GET', '/health')
        self.assertEqual(status, 200); self.assertIn('ports-v1', health['capabilities'])
        identifier = uuid.uuid4().hex
        status, result = self.request('POST', '/v1/generate', {'jobId': identifier, 'script': CREATE_SCRIPT})
        self.assertEqual(status, 200, result)
        self.assertTrue(result['success']); self.assertEqual(len(result['portMetadata']['ports']), 2)
        self.assertEqual(result['jobStatus']['state'], 'succeeded')
        self.assertTrue(result['jobStatus']['terminal']); self.assertTrue(result['jobStatus']['workerStopped'])
        status, port_only = self.request('POST', '/v1/generate', {'jobId': uuid.uuid4().hex, 'script': PORT_ONLY_SCRIPT})
        self.assertTrue(port_only['success'], port_only)
        self.assertEqual(port_only['shapeCount'], 0)
        self.assertEqual(len(port_only['portMetadata']['ports']), 1)
        self.assertTrue(port_only['jobStatus']['terminal']); self.assertTrue(port_only['jobStatus']['workerStopped'])
        legal_script = PORT_ONLY_SCRIPT.replace("info={'onlyPorts':True}", "info={'items':[0]*8190}")
        status, legal = self.request('POST', '/v1/generate', {'jobId': uuid.uuid4().hex, 'script': legal_script})
        self.assertTrue(legal['success'], legal)
        self.assertEqual(len(json.loads(legal['portMetadata']['ports'][0]['infoJson'])['items']), 8190)
        self.assertTrue(legal['jobStatus']['terminal']); self.assertTrue(legal['jobStatus']['workerStopped'])
        status, over_budget = self.request('POST', '/v1/generate', {'jobId': uuid.uuid4().hex,
            'script': legal_script.replace('[0]*8190', '[0]*8191')})
        self.assertFalse(over_budget['success']); self.assertNotIn('gdsBase64', over_budget)
        self.assertIn('8192 JSON value nodes', over_budget['error'])
        self.assertEqual(over_budget['jobStatus']['state'], 'failed')
        self.assertTrue(over_budget['jobStatus']['terminal']); self.assertTrue(over_budget['jobStatus']['workerStopped'])
        identifier = uuid.uuid4().hex
        invalid = CREATE_SCRIPT + "\nadd_port(child,'bad',(0,0),-1,0,7,3)"
        status, failed = self.request('POST', '/v1/generate', {'jobId': identifier, 'script': invalid})
        self.assertFalse(failed['success']); self.assertNotIn('gdsBase64', failed)
        self.assertEqual(failed['jobStatus']['state'], 'failed')
        self.assertTrue(failed['jobStatus']['terminal']); self.assertTrue(failed['jobStatus']['workerStopped'])

    def test_large_single_cell_carrier_refuses_before_successful_artifact(self):
        status, failed = self.request('POST', '/v1/generate', {'jobId': uuid.uuid4().hex,
            'script': 'pass', 'inputMode': 'document', 'currentCellName': 'LARGE_PORTS',
            'documentGds': layout_input(large_owned_layout())})
        self.assertEqual(status, 200)
        self.assertFalse(failed['success']); self.assertNotIn('gdsBase64', failed)
        self.assertIn('300000 value-node', failed['error'])
        self.assertEqual(failed['jobStatus']['state'], 'failed')
        self.assertTrue(failed['jobStatus']['terminal']); self.assertTrue(failed['jobStatus']['workerStopped'])

    def test_precancelled_port_job_cannot_publish_artifact(self):
        identifier = uuid.uuid4().hex
        status, cancelled = self.request('POST', '/v1/jobs/' + identifier + '/cancel', {})
        self.assertEqual(status, 200)
        self.assertTrue(cancelled['terminal']); self.assertTrue(cancelled['workerStopped'])
        status, result = self.request('POST', '/v1/generate', {'jobId': identifier, 'script': CREATE_SCRIPT})
        self.assertFalse(result['success']); self.assertNotIn('gdsBase64', result)
        self.assertEqual(result['jobStatus']['state'], 'cancelled')
        self.assertTrue(result['jobStatus']['terminal']); self.assertTrue(result['jobStatus']['workerStopped'])


if __name__ == '__main__':
    unittest.main()
