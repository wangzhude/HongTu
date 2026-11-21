"""Real worker/job GDS transport preserves supported three-level properties.

Cell/layout properties are the existing nonstandard GDS extension. These tests
do not assert native Port support or gdsfactory/KFactory MetaInfo compatibility.
"""
import base64
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import unittest

import klayout.db as db
from hongtu import bridge
from hongtu.jobs import JobRegistry
from hongtu.policy import PolicyError
from hongtu.worker import execute


CREATE_SCRIPT = """import hongtu as db
layout = db.Layout()
layout.dbu = 0.001
li = layout.layer(68, 20)
top = layout.create_cell('PROPERTY_TOP')
child = layout.create_cell('PROPERTY_CHILD')
empty = layout.create_cell('PROPERTY_EMPTY')
layout.set_property(61, 'library-metadata')
top.set_property(62, 'top-metadata')
child.set_property(63, 'child-metadata')
empty.set_property(64, 'empty-cell-metadata')
shape = child.shapes(li).insert(db.Box(-25, 10, 125, 85))
shape.set_property(65, 'rectangle-metadata')
label = child.shapes(layout.layer(68, 5)).insert(db.Text('LABEL', db.Trans(25, 50)))
label.set_property(66, 'text-metadata')
path = child.shapes(layout.layer(68, 21)).insert(db.Path([db.Point(0, 0), db.Point(100, 0), db.Point(100, 100)], 20, 17, -3))
path.set_property(67, 'path-metadata')
instance = top.insert(db.CellInstArray(child.cell_index(), db.ICplxTrans(1.5, 37, True, -100, 200), db.Vector(400, 60), db.Vector(-50, 300), 3, 2))
instance.set_property(68, 'array-metadata')
local = top.shapes(li).insert(db.Box(-300, -250, -200, -150))
local.set_property(69, 'top-shape-metadata')
"""


def boundary_script(count=64, owner=None, key='i', value="'marker-' + str(i)"):
    body = """import hongtu as db
layout = db.Layout()
layout.dbu = 0.001
li = layout.layer(1, 0)
top = layout.create_cell('BOUNDARY_TOP')
child = layout.create_cell('BOUNDARY_CHILD')
child.shapes(li).insert(db.Box(0, 0, 10, 10))
shape = top.shapes(li).insert(db.Box(20, 0, 30, 10))
instance = top.insert(db.CellInstArray(child.cell_index(), db.Trans(40, 0)))
"""
    owners = ('layout', 'top', 'shape', 'instance') if owner is None else (owner,)
    return body + 'for i in range(' + str(count) + '):\n' + ''.join(
        '    ' + target + '.set_property(' + key + ', ' + value + ')\n' for target in owners)


def maximal_property_script():
    return boundary_script(1, 'shape', key='32767', value="'x' * 65530") + "layout.set_property(1, '中文')\n"


def create_fixture():
    layout = db.Layout()
    layout.dbu = 0.001
    top = layout.create_cell('PROPERTY_TOP')
    child = layout.create_cell('PROPERTY_CHILD')
    empty = layout.create_cell('PROPERTY_EMPTY')
    layer = layout.layer(68, 20)
    layout.set_property(61, 'library-metadata')
    top.set_property(62, 'top-metadata')
    child.set_property(63, 'child-metadata')
    empty.set_property(64, 'empty-cell-metadata')
    shape = child.shapes(layer).insert(db.Box(-25, 10, 125, 85))
    shape.set_property(65, 'rectangle-metadata')
    label = child.shapes(layout.layer(68, 5)).insert(db.Text('LABEL', db.Trans(25, 50)))
    label.set_property(66, 'text-metadata')
    path = child.shapes(layout.layer(68, 21)).insert(
        db.Path([db.Point(0, 0), db.Point(100, 0), db.Point(100, 100)], 20, 17, -3))
    path.set_property(67, 'path-metadata')
    instance = top.insert(db.CellInstArray(child.cell_index(),
        db.ICplxTrans(1.5, 37, True, -100, 200), db.Vector(400, 60), db.Vector(-50, 300), 3, 2))
    instance.set_property(68, 'array-metadata')
    local = top.shapes(layer).insert(db.Box(-300, -250, -200, -150))
    local.set_property(69, 'top-shape-metadata')
    return layout


def extended_gds(layout):
    options = db.SaveLayoutOptions()
    options.format = 'GDS2'
    options.gds2_write_cell_properties = True
    options.gds2_write_file_properties = True
    return layout.write_bytes(options)


def reopen(reply):
    if not reply.get('success'):
        raise AssertionError(reply.get('error'))
    result = db.Layout()
    result.read_bytes(base64.b64decode(reply['gdsBase64'], validate=True))
    return result


def property_snapshot(layout):
    return {
        'library': dict(layout.properties_hash(layout.prop_id)),
        'cells': {cell.name: {
            'properties': dict(cell.properties()),
            'objects': sorted((
                (str(layout.get_info(layer)), str(shape), dict(shape.properties()))
                for layer in layout.layer_indexes() for shape in cell.shapes(layer).each()
            ), key=lambda value: (value[0], value[1])),
            'instances': sorted((str(instance), dict(instance.properties())) for instance in cell.each_inst()),
        } for cell in layout.each_cell()},
    }


class PropertyTransport(unittest.TestCase):
    def setUp(self):
        self.source = create_fixture()
        self.original = extended_gds(self.source)
        self.encoded = base64.b64encode(self.original).decode('ascii')
        self.baseline = db.Layout()
        self.baseline.read_bytes(self.original)

    def assert_preserved(self, actual, expected):
        self.assertEqual(actual.dbu, expected.dbu)
        self.assertEqual(property_snapshot(actual), property_snapshot(expected))
        for expected_cell in expected.each_cell():
            actual_cell = actual.cell(expected_cell.name)
            self.assertIsNotNone(actual_cell)
            for layer in expected.layer_indexes():
                info = expected.get_info(layer)
                other = actual.find_layer(info)
                self.assertIsNotNone(other)
                self.assertTrue((db.Region(expected_cell.begin_shapes_rec(layer)) ^
                                 db.Region(actual_cell.begin_shapes_rec(other))).is_empty(),
                                (expected_cell.name, str(info)))
        instance = list(actual.cell('PROPERTY_TOP').each_inst())[0]
        self.assertEqual(instance.na * instance.nb, 6)
        self.assertAlmostEqual(instance.cplx_trans.angle, 37)
        self.assertAlmostEqual(instance.cplx_trans.mag, 1.5)
        self.assertTrue(instance.cplx_trans.is_mirror())

    def test_new_generation_preserves_library_cell_empty_cell_and_all_object_properties(self):
        reply = bridge.generate(CREATE_SCRIPT)
        actual = reopen(reply)
        self.assert_preserved(actual, self.baseline)
        # Keep the existing bridge count/preview contract; arrays remain compressed.
        self.assertEqual((reply['cellCount'], reply['shapeCount'], reply['expandedShapeCount'], reply['layerCount']), (3, 4, 19, 3))
        # The independent empty Cell is another top; existing single-top SVG
        # preview reports that scope explicitly instead of claiming completeness.
        self.assertTrue(reply['previewTruncated'])

    def test_document_worker_mutates_metadata_without_losing_other_fields(self):
        reply = bridge.generate("current_cell.set_property(62, 'updated-top')\nlayout.set_property(61, 'updated-library')",
                                inputMode='document', documentGds=self.encoded, currentCellName='PROPERTY_TOP')
        expected = db.Layout()
        expected.read_bytes(self.original)
        expected.cell('PROPERTY_TOP').set_property(62, 'updated-top')
        expected.set_property(61, 'updated-library')
        self.assert_preserved(reopen(reply), expected)
        unchanged = db.Layout()
        unchanged.read_bytes(self.original)
        self.assertEqual(property_snapshot(unchanged), property_snapshot(self.baseline))

    def test_selection_worker_preserves_existing_extension_properties(self):
        reply = bridge.generate("print(current_cell.name)", inputMode='selection',
                                selectionGds=self.encoded, currentCellName='PROPERTY_TOP')
        self.assert_preserved(reopen(reply), self.baseline)
        self.assertEqual(reply['stdout'], 'PROPERTY_TOP\n')

    def test_authenticated_job_request_and_terminal_status_preserve_metadata(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), bridge.Handler)
        server.token = 'temporary-property-transport-test-only'
        server.job_lock = threading.Lock()
        server.jobs = JobRegistry()
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        job_id = 'f' * 32
        client = HTTPConnection('127.0.0.1', server.server_port, timeout=20)
        try:
            payload = {'jobId': job_id, 'script': 'print(current_cell.name)', 'inputMode': 'document',
                       'documentGds': self.encoded, 'currentCellName': 'PROPERTY_TOP'}
            client.request('POST', '/v1/generate', json.dumps(payload), {
                'Authorization': 'Bearer ' + server.token, 'Content-Type': 'application/json'})
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            reply = json.loads(response.read())
            self.assert_preserved(reopen(reply), self.baseline)
            expected_status = {'jobId': job_id, 'state': 'succeeded', 'terminal': True, 'workerStopped': True}
            self.assertEqual(reply['jobStatus'], expected_status)
            client.close()
            client = HTTPConnection('127.0.0.1', server.server_port, timeout=10)
            client.request('GET', '/v1/jobs/' + job_id, headers={'Authorization': 'Bearer ' + server.token})
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read()), expected_status)
            self.assertTrue(server.job_lock.acquire(blocking=False))
            server.job_lock.release()
        finally:
            client.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_retained_metadata_obeys_existing_output_budget(self):
        # More than 8 MiB of distinct Cell metadata must fail; stripping it to
        # make a small successful GDS would be silent data loss.
        reply = bridge.generate("""import hongtu as db
layout = db.Layout()
li = layout.layer(1, 0)
top = layout.create_cell('BIG_TOP')
for i in range(600):
    cell = layout.create_cell('BIG_' + str(i))
    cell.set_property(61, str(i) + ':' + 'x' * 15000)
    cell.shapes(li).insert(db.Box(0, 0, 10, 10))
    top.insert(db.CellInstArray(cell.cell_index(), db.Trans(i * 20, 0)))
""")
        self.assertFalse(reply['success'])
        self.assertNotIn('gdsBase64', reply)
        self.assertIn('8 MiB', reply['error'])

    def assert_failed_job(self, server, job_id, script, message):
        client = HTTPConnection('127.0.0.1', server.server_port, timeout=20)
        try:
            client.request('POST', '/v1/generate', json.dumps({'jobId': job_id, 'script': script}), {
                'Authorization': 'Bearer ' + server.token, 'Content-Type': 'application/json'})
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            reply = json.loads(response.read())
            self.assertFalse(reply['success'])
            self.assertNotIn('gdsBase64', reply)
            self.assertIn(message, reply['error'])
            expected = {'jobId': job_id, 'state': 'failed', 'terminal': True, 'workerStopped': True,
                        'error': 'Python task failed'}
            self.assertEqual(reply['jobStatus'], expected)
            client.close()
            client = HTTPConnection('127.0.0.1', server.server_port, timeout=10)
            client.request('GET', '/v1/jobs/' + job_id, headers={'Authorization': 'Bearer ' + server.token})
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read()), expected)
            self.assertTrue(server.job_lock.acquire(blocking=False))
            server.job_lock.release()
        finally:
            client.close()

    def run_failure_cases(self, cases):
        server = ThreadingHTTPServer(('127.0.0.1', 0), bridge.Handler)
        server.token = 'temporary-property-boundary-test-only'
        server.job_lock = threading.Lock()
        server.jobs = JobRegistry()
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for index, (name, script, message) in enumerate(cases):
                with self.subTest(case=name):
                    self.assert_failed_job(server, f'{index + 100:032x}', script, message)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_65_properties_fail_real_jobs_for_all_four_owner_kinds(self):
        self.run_failure_cases([(owner, boundary_script(65, owner), '64 GDS properties')
                                for owner in ('layout', 'top', 'shape', 'instance')])

    def test_64_properties_keep_every_marker_at_all_four_owners(self):
        actual = reopen(bridge.generate(boundary_script()))
        expected = {i: 'marker-' + str(i) for i in range(64)}
        self.assertEqual(dict(actual.properties_hash(actual.prop_id)), expected)
        self.assertEqual(actual.cell('BOUNDARY_TOP').properties(), expected)
        self.assertEqual(list(actual.cell('BOUNDARY_TOP').shapes(actual.find_layer(1, 0)).each())[0].properties(), expected)
        self.assertEqual(list(actual.cell('BOUNDARY_TOP').each_inst())[0].properties(), expected)
        maximal = reopen(bridge.generate(maximal_property_script()))
        self.assertEqual(dict(maximal.properties_hash(maximal.prop_id)), {1: '中文'})
        self.assertEqual(list(maximal.cell('BOUNDARY_TOP').shapes(maximal.find_layer(1, 0)).each())[0].properties(),
                         {32767: 'x' * 65530})

    def test_unrepresentable_metadata_fails_real_jobs_without_a_success_artifact(self):
        cases = [('typed-' + name, boundary_script(1, 'shape', value=value), 'must be strings')
                 for name, value in [('int', '42'), ('float', '1.25'), ('bool', 'True'), ('list', '[1, 2]')]]
        cases += [('key-' + name, boundary_script(1, 'shape', key=key), 'integers in 0..32767')
                  for name, key in [('name', "'named'"), ('negative', '-1'), ('unsigned', '65535')]]
        cases += [('long-string', boundary_script(1, 'shape', value="'x' * 65531"), '65530 UTF-8 bytes'),
                  ('NUL-string', boundary_script(1, 'shape', value="'a\\x00b'"), 'cannot contain NUL')]
        self.run_failure_cases(cases)

    def test_property_validation_happens_before_a_gds_file_is_written(self):
        for script in (boundary_script(65), boundary_script(1, 'shape', value='42')):
            with self.subTest(script=script[-80:]), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(PolicyError):
                    execute({'script': script}, directory)
                self.assertFalse((Path(directory) / 'generated.gds').exists())


if __name__ == '__main__':
    unittest.main()
