"""Real readiness and temporary HTTP routes; no running service or model calls."""
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from importlib import metadata
import json
from pathlib import Path
import threading
import tomllib
import unittest
from unittest.mock import patch

from hongtu import assistant_dependencies as dependencies
from hongtu.bridge import Handler


PYTHON_ROOT = Path(__file__).resolve().parents[1]
TOKEN = "temporary-dependency-http-test-token-only"


class AssistantDependencies(unittest.TestCase):
    def test_install_manifest_covers_all_project_runtime_dependencies_and_extras(self):
        project = tomllib.loads((PYTHON_ROOT / "pyproject.toml").read_text(encoding="utf-8"))
        requirements = [line.strip() for line in (PYTHON_ROOT / "requirements.txt").read_text().splitlines()
                        if line.strip() and not line.lstrip().startswith("#")]
        self.assertEqual(set(requirements), set(project["project"]["dependencies"]))
        self.assertEqual(len(requirements), len(set(requirements)))
        self.assertIn("pydantic-ai-slim[openai,ag-ui]==2.52.0", requirements)
        for name, _, version in dependencies.ASSISTANT_DISTRIBUTIONS:
            expected = f"{name}=={version}" if name != "pydantic-ai-slim" else f"{name}[openai,ag-ui]=={version}"
            self.assertIn(expected, requirements)

    def test_ready_requires_real_installed_versions_and_importable_entry_points(self):
        status = dependencies.assistant_runtime_status()
        self.assertTrue(status["ready"], status.get("error"))
        for name, field, version in dependencies.ASSISTANT_DISTRIBUTIONS:
            self.assertEqual(status[field], metadata.version(name))
            self.assertEqual(status[field], version)
        self.assertNotIn("error", status)

    def test_each_missing_distribution_is_unknown_and_never_imports_an_agent(self):
        original = metadata.version
        for missing, field, _ in dependencies.ASSISTANT_DISTRIBUTIONS:
            with self.subTest(missing=missing):
                def version(name):
                    if name == missing:
                        raise metadata.PackageNotFoundError("private-path-and-token-must-not-leak")
                    return original(name)
                with patch.object(dependencies.metadata, "version", side_effect=version), \
                        patch.object(dependencies, "import_module") as imported:
                    status = dependencies.assistant_runtime_status()
                self.assertFalse(status["ready"])
                self.assertIsNone(status[field])
                imported.assert_not_called()
                self.assertNotIn("private-path", json.dumps(status))

    def test_mismatched_version_is_detected_and_actual_version_is_reported(self):
        original = metadata.version
        with patch.object(dependencies.metadata, "version", side_effect=lambda name: "0.0.0" if name == "pydantic-ai-slim" else original(name)), \
                patch.object(dependencies, "import_module") as imported:
            status = dependencies.assistant_runtime_status()
        self.assertFalse(status["ready"])
        self.assertEqual(status["sdkVersion"], "0.0.0")
        imported.assert_not_called()

    def test_import_failure_is_redacted_and_later_repair_can_recover(self):
        for failed_module in ("ag_ui.core", "ag_ui.encoder", "hongtu.assistant"):
            original = dependencies.import_module
            def import_entry(name):
                if name == failed_module:
                    raise ImportError("private-path-and-token-must-not-leak")
                return original(name)
            with self.subTest(module=failed_module), patch.object(dependencies, "import_module", side_effect=import_entry):
                status = dependencies.assistant_runtime_status()
            self.assertFalse(status["ready"])
            self.assertNotIn("private-path", json.dumps(status))
        self.assertTrue(dependencies.assistant_runtime_status()["ready"])

    def test_startup_checks_isolated_dependencies_before_state_or_restart_and_stop_skips_sdk(self):
        launcher = PYTHON_ROOT.parent / "tools/start_python_bridge.ps1"
        if not launcher.is_file():
            entry = (PYTHON_ROOT / "bridge_entry.py").read_text(encoding="utf-8")
            self.assertIn("_bootstrap_trusted_paths", entry)
            self.assertNotIn("pip install", entry)
            return
        script = launcher.read_text(encoding="utf-8")
        start = script.index("if (-not $Stop) {")
        finish = script.index("New-Item -ItemType Directory -Path $runtimeDir")
        probe = script[start:finish]
        self.assertIn("& $basePythonExe -I -c $dependencyProbeSource", probe)
        self.assertIn("assistant_runtime_status()", probe)
        self.assertLess(finish, script.index("$owned = Get-OwnedBridge"))
        self.assertLess(finish, script.index("Stop-Process -Id $owned.ProcessId"))
        self.assertLess(finish, script.index("--init-config"))
        self.assertLess(finish, script.index("Start-Process -FilePath"))
        self.assertLess(finish, script.index("rport tcp:7865 tcp:7865"))
        self.assertNotIn("pip install", probe)
        self.assertIn("if ($Stop) { return }", script)


class AssistantDependencyHTTP(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server.token = TOKEN
        self.server.job_lock = threading.Lock()
        self.server.assistant_slots = threading.BoundedSemaphore(1)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, method, path, body=None, headers=None):
        merged = {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}
        merged.update(headers or {})
        connection = HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            connection.request(method, path, body=json.dumps({} if body is None else body) if method == "POST" else None,
                               headers=merged)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def missing_sdk(self):
        return patch.object(dependencies.metadata, "version", side_effect=metadata.PackageNotFoundError("private-token/path"))

    def test_health_reports_real_ready_versions_without_invoking_model_or_reading_config(self):
        with patch("hongtu.bridge.load_config", side_effect=AssertionError("health must not read credentials")):
            code, result = self.request("GET", "/health")
        self.assertEqual(code, 200)
        self.assertTrue(result["ok"])
        self.assertIn("assistant-ag-ui", result["capabilities"])
        self.assertTrue(result["assistant"]["ready"])
        for name, field, _ in dependencies.ASSISTANT_DISTRIBUTIONS:
            self.assertEqual(result["assistant"][field], metadata.version(name))

    def test_health_without_sdk_keeps_geometry_and_omits_false_agent_capability(self):
        with self.missing_sdk():
            code, result = self.request("GET", "/health")
        self.assertEqual(code, 200)
        self.assertTrue(result["ok"])
        self.assertIn("generation", result["capabilities"])
        self.assertNotIn("assistant-ag-ui", result["capabilities"])
        self.assertFalse(result["assistant"]["ready"])
        self.assertIsNone(result["assistant"]["harnessVersion"])
        self.assertNotIn("private-token", json.dumps(result))

    def test_post_and_artifact_return_actionable_503_without_acquiring_agent_slot(self):
        with self.missing_sdk():
            for method, path in (("POST", "/v1/assistant"), ("GET", "/v1/assistant/artifacts/" + "a" * 32)):
                with self.subTest(method=method):
                    code, result = self.request(method, path)
                    self.assertEqual(code, 503)
                    self.assertFalse(result["success"])
                    self.assertEqual(result["code"], "ASSISTANT_DEPENDENCIES_UNAVAILABLE")
                    self.assertIn("requirements.txt", result["error"])
                    self.assertNotIn("private-token", json.dumps(result))
        self.assertTrue(self.server.assistant_slots.acquire(blocking=False))
        self.server.assistant_slots.release()

    def test_auth_origin_and_artifact_id_reject_before_dependency_probe(self):
        with patch.object(dependencies, "assistant_runtime_status", side_effect=AssertionError("auth must precede probe")):
            for method, path in (("POST", "/v1/assistant"), ("GET", "/v1/assistant/artifacts/" + "a" * 32)):
                self.assertEqual(self.request(method, path, headers={"Authorization": "Bearer wrong"})[0], 401)
                self.assertEqual(self.request(method, path, headers={"Origin": "http://untrusted.invalid"})[0], 403)
            self.assertEqual(self.request("GET", "/health", headers={"Authorization": "Bearer wrong"})[0], 401)
            self.assertEqual(self.request("GET", "/v1/assistant/artifacts/not-an-id")[0], 400)

    def test_import_failure_and_incompatible_sdk_have_clear_http_failures(self):
        original = metadata.version
        for broken in (patch.object(dependencies, "import_module", side_effect=ImportError("private-token/path")),
                       patch.object(dependencies.metadata, "version", side_effect=lambda name: "0.0.0" if name == "pydantic-ai-slim" else original(name))):
            with broken:
                code, health = self.request("GET", "/health")
                self.assertEqual(code, 200)
                self.assertNotIn("assistant-ag-ui", health["capabilities"])
                self.assertEqual(self.request("POST", "/v1/assistant")[0], 503)
                self.assertEqual(self.request("GET", "/v1/assistant/artifacts/" + "a" * 32)[0], 503)
                self.assertNotIn("private-token", json.dumps(health))

    def test_ordinary_generation_still_executes_real_worker_without_agent_dependencies(self):
        script = "import hongtu as db\nlayout=db.Layout()\nlayout.dbu=0.001\nc=layout.create_cell('DEPENDENCY_TEST')\nc.shapes(layout.layer(1,0)).insert(db.Box(0,0,1000,500))"
        with self.missing_sdk():
            code, result = self.request("POST", "/v1/generate", {"script": script})
        self.assertEqual(code, 200)
        self.assertTrue(result["success"], result.get("error"))
        self.assertEqual(result["shapeCount"], 1)
        self.assertTrue(result["gdsBase64"])


if __name__ == "__main__":
    unittest.main()
