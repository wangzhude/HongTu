"""Current-document execution, isolation and bounded request regression tests."""
import base64
import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

_LOOPBACK_OPENER = build_opener(ProxyHandler({}))
urlopen = _LOOPBACK_OPENER.open

import klayout.db as db
from hongtu.bridge import Handler, generate
from hongtu.policy import PolicyError, validate_request


class WorkspaceExecution(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name, 'source.gds')
        layout = db.Layout()
        layout.dbu = 0.001
        top = layout.create_cell('TOP')
        child = layout.create_cell('CHILD')
        child.shapes(layout.layer(68, 20)).insert(db.Box(0, 0, 100, 200))
        top.insert(db.CellInstArray(child.cell_index(), db.Trans(), db.Vector(300, 0), db.Vector(0, 400), 2, 3))
        layout.write(str(self.path))
        self.original = self.path.read_bytes()
        self.encoded = base64.b64encode(self.original).decode('ascii')

    def reopen(self, result):
        self.assertTrue(result['success'], result.get('error'))
        path = Path(self.folder.name, 'result.gds')
        path.write_bytes(base64.b64decode(result['gdsBase64']))
        layout = db.Layout()
        layout.read(str(path))
        return layout

    def test_document_copy_geometry_and_parameters(self):
        result = generate("import hongtu as db\ncurrent_cell.transform(db.Trans(params['dx'], 0))\nprint(source_layout.cell('TOP').bbox().left)",
                          inputMode='document', documentGds=self.encoded, currentCellName='TOP', parameters={'dx': 120})
        layout = self.reopen(result)
        self.assertEqual(layout.cell('TOP').bbox().left, 120)
        self.assertEqual(result['stdout'], '0\n')
        self.assertEqual(result['expandedShapeCount'], 6)
        self.assertEqual(self.path.read_bytes(), self.original)
        instance = list(layout.cell('TOP').each_inst())[0]
        self.assertEqual(instance.na * instance.nb, 6)
        self.assertEqual(sorted([instance.na, instance.nb]), [2, 3])
        self.assertEqual(str(layout.get_info(layout.layer_indexes()[0])), '68/20')

    def test_selection_snapshot_and_failure_leave_source_unchanged(self):
        result = generate("import hongtu as db\ncurrent_cell.transform(db.Trans(0, 50))", inputMode='selection', selectionGds=self.encoded)
        layout = self.reopen(result)
        self.assertEqual(layout.top_cell().bbox().bottom, 50)
        failed = generate("layout.clear()\nx = 1/0", inputMode='document', documentGds=self.encoded)
        self.assertFalse(failed['success'])
        self.assertEqual(self.path.read_bytes(), self.original)

    def test_sweep_runs_are_independent(self):
        for dx in (10, 20, 30):
            result = generate("import hongtu as db\ncurrent_cell.transform(db.Trans(params['dx'], 0))",
                              inputMode='document', documentGds=self.encoded, parameters={'dx': dx})
            layout = self.reopen(result)
            self.assertEqual(layout.top_cell().bbox().left, dx)

    def test_inputs_cannot_grant_filesystem_or_import_capabilities(self):
        for script in ("source_layout.write('outside.gds')", "source_layout.read('secret.gds')", "import os", "params.__class__"):
            self.assertFalse(generate(script, inputMode='document', documentGds=self.encoded)['success'])
        for values in ({'inputMode': []}, {'parameters': {'x': []}}, {'parameters': {'x': 10**400}},
                       {'parameters': {'_secret': 1}}, {'documentGds': '%%%'}):
            with self.subTest(values=str(values)[:70]), self.assertRaises(PolicyError):
                validate_request({'script': 'x=1', **values})
        self.assertFalse(generate('x=1', inputMode='selection')['success'])

    def test_authenticated_http_accepts_input_and_rejects_extra_fields(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.token = 't' * 40
        server.job_lock = threading.Lock()
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            endpoint = 'http://127.0.0.1:' + str(server.server_port) + '/v1/generate'
            def request(payload):
                return Request(endpoint, data=json.dumps(payload).encode(), headers={
                    'Content-Type': 'application/json', 'Authorization': 'Bearer ' + server.token})
            with urlopen(request({'script': 'print(params["tag"])', 'inputMode': 'document',
                                  'documentGds': self.encoded, 'parameters': {'tag': 'ok'}}), timeout=20) as response:
                result = json.load(response)
            self.assertTrue(result['success'], result.get('error'))
            self.assertEqual(result['stdout'], 'ok\n')
            with self.assertRaises(HTTPError) as error:
                urlopen(request({'script': 'x=1', 'inputMode': []}), timeout=5)
            self.assertEqual(error.exception.code, 400)
            with self.assertRaises(HTTPError) as error:
                urlopen(request({'script': 'x=1', 'path': 'secret.gds'}), timeout=5)
            self.assertEqual(error.exception.code, 400)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_verification_http_reports_real_violations_and_rejects_untrusted_deck_code(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.token = 'v' * 40
        server.job_lock = threading.Lock()
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        payload = {'kind': 'drc', 'technologyId': 'sky130', 'deckId': 'sky130-met1-public',
                   'documentGds': self.encoded}
        try:
            endpoint = 'http://127.0.0.1:' + str(server.server_port) + '/v1/verify'
            def request(body, headers=None):
                return Request(endpoint, data=json.dumps(body).encode(), headers=headers or {
                    'Content-Type': 'application/json', 'Authorization': 'Bearer ' + server.token})
            with urlopen(request(payload), timeout=30) as response:
                result = json.load(response)
            self.assertTrue(result['success'], result['error'])
            self.assertTrue(result['complete'])
            self.assertFalse(result['passed'])  # 100nm-wide geometry violates public met1 width.
            self.assertGreater(result['violationCount'], 0)
            self.assertFalse(result['foundrySignoff'])
            self.assertIn('scope', result)
            for headers, expected in [({'Content-Type': 'application/json'}, 401),
                                      ({'Authorization': 'Bearer ' + server.token, 'Origin': 'https://untrusted.example'}, 403)]:
                with self.assertRaises(HTTPError) as error:
                    urlopen(request(payload, headers), timeout=5)
                self.assertEqual(error.exception.code, expected)
            with self.assertRaises(HTTPError) as error:
                urlopen(request({**payload, 'script': 'import os'}), timeout=5)
            self.assertEqual(error.exception.code, 400)
            server.job_lock.acquire()
            try:
                with self.assertRaises(HTTPError) as error:
                    urlopen(request(payload), timeout=5)
                self.assertEqual(error.exception.code, 429)
            finally:
                server.job_lock.release()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
