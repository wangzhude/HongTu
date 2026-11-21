"""Meaningful end-to-end checks against real CPython/KLayout and the HTTP bridge."""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener

_LOOPBACK_OPENER = build_opener(ProxyHandler({}))
urlopen = _LOOPBACK_OPENER.open

import klayout.db as db
from hongtu.bridge import CONFIG_PATH, generate
from hongtu import bridge
from hongtu.limits import WindowsJob
from hongtu.policy import PolicyError, validate_script

ROOT = Path(__file__).resolve().parents[1]


class GeneratedLayouts(unittest.TestCase):
    def test_named_and_empty_layers_are_returned_outside_gds(self):
        result = generate("""import hongtu as db
layout = db.Layout()
layout.dbu = 0.001
top = layout.create_cell('INVERTER')
active = layout.layer(db.LayerInfo(2, 0, 'ACTIVE'))
labels = layout.layer(db.LayerInfo(7, 1, 'METAL1_LABEL'))
empty = layout.layer(db.LayerInfo(10, 0, 'MARKER'))
top.shapes(active).insert(db.Box(0, 0, 100, 200))
top.shapes(labels).insert(db.Text('IN', db.Trans(10, 20)))
""")
        self.assertTrue(result['success'], result.get('error'))
        self.assertEqual(result['layerDefinitions'], [
            {'layerNumber': 2, 'datatype': 0, 'name': 'ACTIVE'},
            {'layerNumber': 7, 'datatype': 1, 'name': 'METAL1_LABEL'},
            {'layerNumber': 10, 'datatype': 0, 'name': 'MARKER'}])
        self.assertEqual(result['layerCount'], 3)
        layout = db.Layout()
        layout.read_bytes(base64.b64decode(result['gdsBase64']))
        self.assertEqual(len(list(layout.layer_indexes())), 2)
        self.assertTrue(all(layout.get_info(i).name == '' for i in layout.layer_indexes()))

    def test_layer_metadata_rejects_control_names_and_invalid_numbers(self):
        cases = [(1, 0, 'line\nbreak'), (1, 0, 'nul\0name'), (1, 0, '\u0085'),
                 (1, 0, '名' * 86), (32768, 0, ''), (1, 32768, '')]
        for layer, datatype, name in cases:
            with self.subTest(layer=layer, datatype=datatype, name_length=len(name)):
                script = ("import hongtu as db\nlayout=db.Layout()\ntop=layout.create_cell('TOP')\n"
                          f"li=layout.layer(db.LayerInfo({layer},{datatype},{name!r}))\n"
                          "top.shapes(li).insert(db.Box(0,0,100,100))")
                result = generate(script)
                self.assertFalse(result['success'])
                self.assertNotIn('gdsBase64', result)

    def test_layer_metadata_boundary_values_and_utf8_names(self):
        name = '名' * 85 + 'A'  # 256 UTF-8 bytes.
        result = generate("import hongtu as db\nlayout=db.Layout()\ntop=layout.create_cell('TOP')\n"
                          f"li=layout.layer(db.LayerInfo(32767,32767,{name!r}))\n"
                          "top.shapes(li).insert(db.Box(0,0,100,100))\nlayout.layer(0,0)")
        self.assertTrue(result['success'], result.get('error'))
        self.assertEqual(result['layerDefinitions'], [
            {'layerNumber': 32767, 'datatype': 32767, 'name': name},
            {'layerNumber': 0, 'datatype': 0, 'name': ''}])

    def test_layer_metadata_rejects_duplicate_pairs_and_layer_budget(self):
        from hongtu.worker import collect_layer_definitions
        layout = db.Layout()
        one = layout.insert_layer(db.LayerInfo(1, 0, 'A'))
        two = layout.insert_layer(db.LayerInfo(1, 0, 'B'))
        with self.assertRaisesRegex(PolicyError, 'duplicate'):
            collect_layer_definitions(layout, [one, two])
        with self.assertRaisesRegex(PolicyError, '1..256'):
            collect_layer_definitions(layout, [])
        for number in range(2, 257):
            layout.insert_layer(db.LayerInfo(number, 0, ''))
        with self.assertRaisesRegex(PolicyError, '1..256'):
            collect_layer_definitions(layout, list(layout.layer_indexes()))

    def test_own_examples_reopen_gds_and_oasis(self):
        for source in sorted((ROOT / "examples").glob("*.py")):
            with self.subTest(source=source.name), tempfile.TemporaryDirectory() as folder:
                result = generate(source.read_text(encoding="utf-8"))
                self.assertTrue(result["success"], result.get("error"))
                gds = Path(folder, "result.gds")
                gds.write_bytes(base64.b64decode(result["gdsBase64"]))
                reread = db.Layout()
                reread.read(str(gds))
                self.assertEqual(reread.cells(), result["cellCount"])
                self.assertEqual(len(list(reread.layer_indexes())), result["layerCount"])
                self.assertIn('fill-rule="evenodd"', result["previewSvg"])
                oasis = Path(folder, "result.oas")
                reread.write(str(oasis))
                roundtrip = db.Layout()
                roundtrip.read(str(oasis))
                self.assertEqual(roundtrip.cells(), reread.cells())
                # Independent format readers preserve per-layer geometry after flattening.
                for a in reread.top_cells():
                    b = roundtrip.cell(a.name)
                    self.assertIsNotNone(b)
                    for li in reread.layer_indexes():
                        info = reread.get_info(li)
                        other = roundtrip.find_layer(info)
                        self.assertIsNotNone(other)
                        ra = db.Region(a.begin_shapes_rec(li))
                        rb = db.Region(b.begin_shapes_rec(other))
                        self.assertTrue((ra ^ rb).is_empty(), (source.name, str(info)))

    def test_real_python_functions_and_import_forms(self):
        source = """import klayout.db as db
from math import sin, pi
def make_box(x):
    return db.Box(x, 0, x + 100, 200)
layout = db.Layout()
top = layout.create_cell('TOP')
for n in range(3):
    top.shapes(layout.layer(1, 0)).insert(make_box(n * 200))
print(sin(pi / 2))
"""
        result = generate(source)
        self.assertTrue(result["success"], result.get("error"))
        self.assertEqual(result["shapeCount"], 3)
        self.assertEqual(result["stdout"], "1.0\n")

    def test_unsafe_operations_are_rejected_before_execution(self):
        for source in ["import os", "import subprocess", "import socket", "import pathlib",
                       "x = ().__class__", "import hongtu as db\ndb.Layout().read('secret.gds')",
                       "import hongtu as db\ndb.Layout().write('outside.gds')",
                       "from hongtu import SaveLayoutOptions", "while True: pass"]:
            with self.subTest(source=source):
                with self.assertRaises(PolicyError):
                    validate_script(source)
        for source in ["open('secret')", "eval('1')", "exec('1')"]:
            self.assertFalse(generate(source)["success"])

    def test_result_required_and_resource_boundaries(self):
        self.assertFalse(generate("x = 1")["success"])
        self.assertFalse(generate("return 1")["success"])
        self.assertFalse(generate("x = list(range(100001))")["success"])
        source = """import hongtu as db
layout = db.Layout()
top = layout.create_cell('TOP')
child = layout.create_cell('CHILD')
child.shapes(layout.layer(1, 0)).insert(db.Box(0, 0, 10, 10))
top.insert(db.CellInstArray(child.cell_index(), db.Trans(), db.Vector(20,0), db.Vector(0,20), 1000, 1000))
"""
        self.assertIn("200000", generate(source)["error"])
        # 4000-shape output stays complete while its preview is explicitly bounded.
        source = source.replace("1000, 1000", "100, 40")
        result = generate(source)
        self.assertTrue(result["success"], result.get("error"))
        self.assertEqual(result["expandedShapeCount"], 4000)
        self.assertTrue(result["previewTruncated"])

    def test_long_running_child_is_terminated(self):
        source = "for x in range(100000):\n    for y in range(100000):\n        z = x + y\n"
        result = generate(source)
        self.assertFalse(result["success"])
        self.assertRegex(result["error"], "timeout|resource limit")

    def test_forced_timeouts_reap_owned_worker_close_pipes_and_remove_directory(self):
        started = []
        real_popen = subprocess.Popen

        def launch(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            started.append((process, kwargs["cwd"], args[0][0]))
            return process

        source = "for x in range(100000):\n    for y in range(100000):\n        z = x + y\n"
        with mock.patch.object(bridge.subprocess, "Popen", side_effect=launch), \
                mock.patch.object(bridge, "TIMEOUT_SECONDS", 0.2):
            for _ in range(4):
                result = generate(source)
                self.assertFalse(result["success"])
                self.assertIn("timeout", result["error"])
                process, folder, executable = started[-1]
                self.assertIsNotNone(process.poll())
                self.assertTrue(process.stdin.closed)
                self.assertFalse(Path(folder).exists())
                if os.name == "nt":
                    self.assertEqual(Path(executable), Path(sys._base_executable))

    @unittest.skipUnless(os.name == "nt", "Windows resource-job lifecycle")
    def test_failed_job_assignment_reaps_only_started_worker(self):
        started = []
        real_popen = subprocess.Popen

        def launch(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            started.append((process, kwargs["cwd"]))
            return process

        with mock.patch.object(bridge.subprocess, "Popen", side_effect=launch), \
                mock.patch.object(bridge, "WindowsJob", side_effect=OSError("injected assignment rejection")):
            result = generate("x = 1")
        self.assertFalse(result["success"])
        self.assertIn("could not start", result["error"])
        self.assertEqual(len(started), 1)
        process, folder = started[0]
        self.assertIsNotNone(process.poll())
        self.assertTrue(process.stdin.closed)
        self.assertFalse(Path(folder).exists())

    @unittest.skipUnless(os.name == "nt", "Windows descendant and cwd handle lifecycle")
    def test_job_close_waits_for_owned_descendant_and_preserves_unrelated_process(self):
        executable = sys._base_executable
        independent = subprocess.Popen([executable, "-I", "-c", "import sys;sys.stdin.readline()"],
                                       stdin=subprocess.PIPE, creationflags=subprocess.CREATE_NO_WINDOW)
        job = None
        process = None
        try:
            with bridge.worker_directory() as folder:
                child = "import time;time.sleep(30)"
                script = ("import subprocess,sys;sys.stdin.readline();"
                          "child=subprocess.Popen([sys.executable,'-I','-c',sys.argv[1]],"
                          "creationflags=subprocess.CREATE_NO_WINDOW);"
                          "open('owned-child.pid','w').write(str(child.pid))")
                process = subprocess.Popen([executable, "-I", "-c", script, child], cwd=folder,
                                           stdin=subprocess.PIPE, creationflags=subprocess.CREATE_NO_WINDOW)
                job = WindowsJob(process, 128 * 1024 * 1024)
                process.communicate(b"start\n", timeout=5)
                self.assertEqual(process.returncode, 0)
                self.assertTrue(Path(folder, "owned-child.pid").is_file())
                job.close()
                self.assertIsNone(job.handle)
                self.assertIsNone(independent.poll())
            self.assertFalse(Path(folder).exists())
        finally:
            if job is not None:
                job.close()
            if process is not None:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
                if process.stdin is not None:
                    process.stdin.close()
            independent.kill()
            independent.wait(timeout=5)
            independent.stdin.close()

    @unittest.skipUnless(os.name == "nt", "Windows sharing errors")
    def test_directory_cleanup_retries_transient_locks_but_raises_permanent_failure(self):
        for permanent in (False, True):
            with self.subTest(permanent=permanent):
                directory = tempfile.TemporaryDirectory(prefix="hongtu-cleanup-test-")
                cleanup = directory.cleanup
                locked = PermissionError("injected sharing lock")
                locked.winerror = 32
                attempts = []

                def attempt():
                    attempts.append(1)
                    if permanent or len(attempts) < 3:
                        raise locked
                    cleanup()

                try:
                    with mock.patch.object(bridge.tempfile, "TemporaryDirectory", return_value=directory), \
                            mock.patch.object(directory, "cleanup", side_effect=attempt), \
                            mock.patch.object(bridge.time, "sleep"):
                        if permanent:
                            with self.assertRaisesRegex(PermissionError, "sharing lock"):
                                with bridge.worker_directory():
                                    pass
                            self.assertEqual(len(attempts), 6)
                            self.assertTrue(Path(directory.name).exists())
                        else:
                            with bridge.worker_directory():
                                pass
                            self.assertEqual(len(attempts), 3)
                            self.assertFalse(Path(directory.name).exists())
                finally:
                    cleanup()

    def test_directory_cleanup_does_not_suppress_original_failure(self):
        with self.assertRaisesRegex(ValueError, "original failure"):
            with bridge.worker_directory() as folder:
                raise ValueError("original failure")
        self.assertFalse(Path(folder).exists())


class HttpContract(unittest.TestCase):
    _owned_process = None
    _owned_temp = None

    @classmethod
    def setUpClass(cls):
        import secrets, socket, time
        from urllib.error import URLError
        if CONFIG_PATH.is_file():
            try:
                candidate = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
                with urlopen(candidate["endpoint"] + "/health", timeout=1) as resp:
                    if json.load(resp).get("ok"):
                        cls.config = candidate
                        cls.endpoint = candidate["endpoint"]
                        return
            except (OSError, ValueError, KeyError, URLError):
                pass
        cls._owned_temp = tempfile.TemporaryDirectory(prefix="hongtu-http-contract-")
        cls.addClassCleanup(cls._cleanup_owned_bridge)
        folder = Path(cls._owned_temp.name)
        token = secrets.token_urlsafe(32)
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            port = reserved.getsockname()[1]
        endpoint = f"http://127.0.0.1:{port}"
        cfg_dir = folder / "HongTu" / "python-bridge"
        cfg_dir.mkdir(parents=True, exist_ok=True)
        cls.config = {"endpoint": endpoint, "port": port, "token": token}
        (cfg_dir / "config.json").write_text(json.dumps(cls.config), encoding="utf-8")
        env = dict(os.environ)
        if os.name == "nt":
            env["LOCALAPPDATA"] = str(folder)
        else:
            env["XDG_DATA_HOME"] = str(folder)
        kwargs = {"cwd": str(folder), "env": env, "stdin": subprocess.DEVNULL,
                  "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
        executable = getattr(sys, "_base_executable", sys.executable)
        cls._owned_process = subprocess.Popen(
            [executable, "-I", str(ROOT / "bridge_entry.py"), "--port", str(port)], **kwargs)
        cls.endpoint = endpoint
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if cls._owned_process.poll() is not None:
                raise RuntimeError("isolated bridge_entry exited early")
            try:
                with urlopen(endpoint + "/health", timeout=1) as resp:
                    if json.load(resp).get("ok"):
                        return
            except (URLError, TimeoutError):
                time.sleep(0.05)
        raise RuntimeError("isolated bridge_entry did not become healthy in time")

    @classmethod
    def _cleanup_owned_bridge(cls):
        if cls._owned_process is not None:
            cls._owned_process.terminate()
            try:
                cls._owned_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cls._owned_process.kill()
                cls._owned_process.wait(timeout=5)
            cls._owned_process = None
        if cls._owned_temp is not None:
            import time
            for attempt, delay in enumerate((0, 0.05, 0.1, 0.2, 0.4, 0.8)):
                if delay:
                    time.sleep(delay)
                try:
                    cls._owned_temp.cleanup()
                    break
                except PermissionError as exc:
                    if os.name != "nt" or getattr(exc, "winerror", None) not in (5, 32, 33) or attempt == 5:
                        raise
            cls._owned_temp = None

    def request(self, path, payload=None, token=True):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + self.config["token"]
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        with urlopen(Request(self.endpoint + path, data=data, headers=headers), timeout=20) as response:
            return json.load(response)

    def test_health_and_bearer_requirement(self):
        health = self.request("/health", token=False)
        self.assertEqual(health["execution"], "host-companion")
        with self.assertRaises(HTTPError) as error:
            self.request("/v1/generate", {"script": "x=1"}, token=False)
        self.assertEqual(error.exception.code, 401)
        self.assertNotIn("token", health)
        with self.assertRaises(HTTPError) as error:
            with urlopen(Request(self.endpoint + "/health", headers={"Authorization": "Bearer invalid"}), timeout=5):
                pass
        self.assertEqual(error.exception.code, 401)

    def test_real_http_generation(self):
        script = (ROOT / "examples" / "region_holes.py").read_text(encoding="utf-8")
        result = self.request("/v1/generate", {"script": script})
        self.assertTrue(result["success"], result.get("error"))
        self.assertEqual(result["layerCount"], 3)
        self.assertGreater(len(base64.b64decode(result["gdsBase64"])), 100)
        self.assertNotIn(self.config["token"], json.dumps(result))

    def test_no_file_or_shell_endpoint(self):
        with self.assertRaises(HTTPError) as error:
            self.request("/file?path=C:/Windows/win.ini")
        self.assertEqual(error.exception.code, 404)
        with self.assertRaises(HTTPError) as error:
            self.request("/v1/generate", {"script": "x=1", "fileName": "../outside"})
        self.assertEqual(error.exception.code, 400)


    def test_companion_endpoint_allows_loopback_http_and_lan_https_only(self):
        cases = [
            ("http://127.0.0.1:7865", ("http", "127.0.0.1", 7865)),
            ("http://localhost:7865", ("http", "localhost", 7865)),
            ("http://[::1]:7865", ("http", "::1", 7865)),
            ("https://192.168.1.25:7865/", ("https", "192.168.1.25", 7865)),
            ("https://companion.local:8443", ("https", "companion.local", 8443)),
            ("https://[fd00::1]:7865", ("https", "fd00::1", 7865)),
        ]
        for valid, expected in cases:
            self.assertEqual(bridge.validate_companion_endpoint(valid), expected)
        for invalid in ("http://192.168.1.25:7865", "http://0.0.0.0:7865", "https://0.0.0.0:7865",
                        "https://user:secret@192.168.1.25:7865", "https://192.168.1.25:7865/v1", "ftp://127.0.0.1:7865"):
            with self.assertRaises(ValueError):
                bridge.validate_companion_endpoint(invalid)

if __name__ == "__main__":
    unittest.main(verbosity=2)
