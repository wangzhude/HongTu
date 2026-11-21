"""Owned-process cancellation over temporary HTTP; no live service or secrets."""
import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

import klayout.db as db
from hongtu import bridge, verification
from hongtu.jobs import JobRegistry, JobCapacity, JobConflict, WorkerControl, validate_job_id

TOKEN = "temporary-cancellation-test-token-only"
SCRIPT = "import hongtu as db\nlayout=db.Layout()\nlayout.dbu=0.001\nc=layout.create_cell('TEST')\nc.shapes(layout.layer(1,0)).insert(db.Box(0,0,1000,500))"
LONG_SCRIPT = "for x in range(100000):\n    for y in range(100000):\n        value = x + y\n"


class JobRegistryTests(unittest.TestCase):
    def test_strict_ids_capacity_expiry_and_active_jobs_never_evict(self):
        now = [1.0]
        registry = JobRegistry(capacity=2, retention=10, clock=lambda: now[0])
        for invalid in (None, True, 1, "a" * 31, "A" * 32, "../" + "a" * 29, "a" * 32 + "\n"):
            with self.assertRaises(ValueError):
                validate_job_id(invalid)
        registry.cancel("a" * 32)
        active, fresh = registry.register("b" * 32)
        self.assertTrue(fresh)
        with self.assertRaises(JobCapacity):
            registry.cancel("c" * 32)
        now[0] += 11
        self.assertIsNone(registry.get("a" * 32))
        self.assertIs(registry.get("b" * 32), active)
        registry.cancel("c" * 32)
        with self.assertRaises(JobConflict):
            registry.register("b" * 32)

    def test_cancel_before_start_blocks_late_registration_without_process(self):
        registry = JobRegistry()
        status = registry.cancel("1" * 32)
        control, fresh = registry.register("1" * 32)
        self.assertFalse(fresh)
        self.assertEqual(status, control.snapshot())
        self.assertEqual(status["state"], "cancelled")
        self.assertTrue(status["terminal"] and status["workerStopped"])
        factory = mock.Mock()
        with self.assertRaisesRegex(Exception, "cancelled"):
            control.spawn(factory)
        factory.assert_not_called()

    def test_success_is_immutable_and_cancel_waits_for_final_cleanup(self):
        control = WorkerControl("2" * 32)
        status = control.request_cancel(wait_seconds=0)
        self.assertEqual(status["state"], "cancelling")
        self.assertFalse(status["terminal"])
        released = []
        status = control.complete(True, lambda: released.append(True))
        self.assertEqual(status["state"], "cancelled")
        self.assertEqual(released, [True])
        control = WorkerControl("3" * 32)
        status = control.complete(True, lambda: None)
        self.assertEqual(control.request_cancel(), status)
        self.assertEqual(status["state"], "succeeded")

    def test_unconfirmed_termination_never_releases_slot_or_claims_terminal(self):
        control = WorkerControl("4" * 32)
        control._worker_stopped = False
        released = mock.Mock()
        status = control.complete(False, released)
        self.assertFalse(status["terminal"])
        self.assertFalse(status["workerStopped"])
        self.assertEqual(status["state"], "cancelling")
        released.assert_not_called()


class OrdinaryJobHTTP(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), bridge.Handler)
        self.server.token = TOKEN
        self.server.job_lock = threading.Lock()
        self.server.jobs = JobRegistry()
        self.server.assistant_slots = threading.BoundedSemaphore(2)
        self.server.daemon_threads = True
        self.server.errors = []
        self.server.handle_error = lambda request, address: self.server.errors.append(type(sys.exception()).__name__)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.pool = ThreadPoolExecutor(max_workers=3)
        self.jobs = []

    def tearDown(self):
        for job_id in self.jobs:
            control = self.server.jobs.get(job_id)
            if control is not None and not control.snapshot()["terminal"]:
                control.request_cancel()
        self.pool.shutdown(wait=True)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.assertEqual(self.server.errors, [], "no HTTP callback exception may escape")

    def request(self, method, path, body=None, *, headers=None):
        client = HTTPConnection("127.0.0.1", self.server.server_port, timeout=20)
        try:
            supplied = {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"} if headers is None else headers
            client.request(method, path, body=None if body is None else json.dumps(body), headers=supplied)
            response = client.getresponse()
            return response.status, json.loads(response.read())
        finally:
            client.close()

    def start(self, job_id, *, body=None, route="/v1/generate"):
        self.jobs.append(job_id)
        return self.pool.submit(self.request, "POST", route, body or {"script": LONG_SCRIPT, "jobId": job_id})

    def running(self, job_id):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            control = self.server.jobs.get(job_id)
            if control is not None and control.snapshot()["state"] == "running":
                return control
            time.sleep(0.01)
        self.fail("temporary test worker did not enter running state")

    def assert_slot_free(self):
        self.assertTrue(self.server.job_lock.acquire(blocking=False))
        self.server.job_lock.release()

    def test_real_generate_cancel_reaps_worker_removes_temp_and_keeps_unrelated_process(self):
        executable = getattr(sys, "_base_executable", sys.executable) if os.name == "nt" else sys.executable
        options = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
        independent = subprocess.Popen([executable, "-I", "-c", "import sys;sys.stdin.readline()"],
                                       stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **options)
        try:
            job_id = "a" * 32
            pending = self.start(job_id)
            control = self.running(job_id)
            process = control._process
            folder = Path(process.args[-1])
            self.assertTrue(folder.is_dir())
            status, cancellation = self.request("POST", f"/v1/jobs/{job_id}/cancel", {})
            self.assertIn(status, (200, 202))
            code, reply = pending.result(timeout=12)
            self.assertEqual(code, 200)
            self.assertFalse(reply["success"])
            self.assertNotIn("gdsBase64", reply)
            self.assertEqual(reply["jobStatus"]["state"], "cancelled")
            self.assertTrue(reply["jobStatus"]["workerStopped"])
            self.assertIsNotNone(process.poll())
            self.assertTrue(process.stdin.closed)
            self.assertFalse(folder.exists())
            self.assertIsNone(independent.poll())
            self.assert_slot_free()
            code, status = self.request("GET", f"/v1/jobs/{job_id}")
            self.assertEqual(code, 200)
            self.assertEqual(status, reply["jobStatus"])
            self.assertEqual(self.request("POST", f"/v1/jobs/{job_id}/cancel", {})[1], status)
            # A confirmed cancellation leaves no hidden busy worker behind.
            code, next_reply = self.request("POST", "/v1/generate", {"script": SCRIPT, "jobId": "b" * 32})
            self.assertEqual(code, 200)
            self.assertTrue(next_reply["success"])
        finally:
            independent.kill()
            independent.wait(timeout=5)
            independent.stdin.close()

    def test_early_cancel_tombstone_prevents_worker_even_if_post_arrives_later(self):
        job_id = "c" * 32
        code, before = self.request("POST", f"/v1/jobs/{job_id}/cancel", {})
        self.assertEqual(code, 200)
        with mock.patch.object(bridge.subprocess, "Popen") as launch:
            code, reply = self.request("POST", "/v1/generate", {"script": SCRIPT, "jobId": job_id})
        launch.assert_not_called()
        self.assertEqual(code, 200)
        self.assertFalse(reply["success"])
        self.assertEqual(reply["jobStatus"], before)
        self.assert_slot_free()

    def test_completed_success_wins_and_duplicate_id_never_executes_again(self):
        job_id = "d" * 32
        code, reply = self.request("POST", "/v1/generate", {"script": SCRIPT, "jobId": job_id})
        self.assertEqual(code, 200)
        self.assertTrue(reply["success"])
        self.assertEqual(reply["jobStatus"]["state"], "succeeded")
        self.assertIsNone(self.server.jobs.get(job_id)._process)
        self.assertGreater(len(base64.b64decode(reply["gdsBase64"])), 20)
        self.assertEqual(self.request("POST", f"/v1/jobs/{job_id}/cancel", {})[1], reply["jobStatus"])
        self.assertEqual(self.request("POST", "/v1/generate", {"script": SCRIPT, "jobId": job_id})[0], 409)

    def test_active_duplicate_and_other_busy_request_cannot_steal_ownership(self):
        job_id = "e" * 32
        pending = self.start(job_id)
        control = self.running(job_id)
        self.assertEqual(self.request("POST", "/v1/generate", {"script": SCRIPT, "jobId": job_id})[0], 409)
        code, busy = self.request("POST", "/v1/generate", {"script": SCRIPT, "jobId": "f" * 32})
        self.assertEqual(code, 429)
        self.assertEqual(busy["jobStatus"]["state"], "failed")
        self.assertFalse(control.snapshot()["terminal"])
        self.request("POST", f"/v1/jobs/{job_id}/cancel", {})
        self.assertFalse(pending.result(timeout=12)[1]["success"])

    def test_timeout_reports_distinct_terminal_state_after_real_reap(self):
        job_id = "1" * 32
        with mock.patch.object(bridge, "TIMEOUT_SECONDS", 0.2):
            code, reply = self.request("POST", "/v1/generate", {"script": LONG_SCRIPT, "jobId": job_id})
        self.assertEqual(code, 200)
        self.assertFalse(reply["success"])
        self.assertEqual(reply["jobStatus"]["state"], "timed_out")
        self.assertTrue(reply["jobStatus"]["workerStopped"])
        self.assert_slot_free()

    def test_legacy_sync_generation_and_health_remain_compatible(self):
        code, reply = self.request("POST", "/v1/generate", {"script": SCRIPT})
        self.assertEqual(code, 200)
        self.assertTrue(reply["success"])
        self.assertNotIn("jobId", reply)
        self.assertNotIn("jobStatus", reply)
        health = self.request("GET", "/health")[1]
        self.assertIn("job-cancellation-v1", health["capabilities"])
        self.assertIn("assistant-ag-ui", health["capabilities"])

    def test_job_endpoints_preserve_auth_origin_path_and_small_body_boundaries(self):
        path = "/v1/jobs/" + "2" * 32
        self.assertEqual(self.request("GET", path, headers={})[0], 401)
        self.assertEqual(self.request("POST", path + "/cancel", {}, headers={})[0], 401)
        headers = {"Authorization": "Bearer " + TOKEN, "Origin": "https://untrusted.example"}
        self.assertEqual(self.request("POST", path + "/cancel", {}, headers=headers)[0], 403)
        self.assertEqual(self.request("GET", path, headers=headers)[0], 403)
        self.assertEqual(self.request("GET", path)[0], 404)
        self.assertEqual(self.request("GET", "/v1/jobs/INVALID")[0], 400)
        self.assertEqual(self.request("POST", path + "/cancel", {"pid": 1})[0], 400)
        self.assertEqual(self.request("POST", path + "/cancel", {"data": "x" * 1024})[0], 413)
        self.assertEqual(self.request("POST", "/v1/generate", {"script": SCRIPT, "jobId": "bad"})[0], 400)

    def test_slow_upload_has_total_deadline_and_never_reaches_worker(self):
        client = HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        try:
            with mock.patch.object(bridge, "ORDINARY_BODY_SECONDS", 0.1), \
                    mock.patch.object(bridge.subprocess, "Popen") as launch:
                client.putrequest("POST", "/v1/generate")
                client.putheader("Authorization", "Bearer " + TOKEN)
                client.putheader("Content-Length", "100")
                client.endheaders()
                client.send(b"{")
                response = client.getresponse()
                self.assertEqual(response.status, 408)
                response.read()
                launch.assert_not_called()
            self.assert_slot_free()
        finally:
            client.close()

    def test_cleanup_failure_does_not_publish_success_or_raw_error(self):
        original = bridge.worker_directory

        @contextmanager
        def failing_cleanup():
            with original() as folder:
                yield folder
            raise PermissionError("private-test-path-not-for-response")

        with mock.patch.object(bridge, "worker_directory", failing_cleanup):
            code, reply = self.request("POST", "/v1/generate", {"script": SCRIPT, "jobId": "5" * 32})
        self.assertEqual(code, 200)
        self.assertFalse(reply["success"])
        self.assertNotIn("gdsBase64", reply)
        self.assertNotIn("private-test-path", json.dumps(reply))
        self.assertEqual(reply["jobStatus"]["state"], "failed")
        self.assertTrue(reply["jobStatus"]["workerStopped"])
        self.assert_slot_free()

    def test_cancel_waits_for_cleanup_and_never_calls_kill_a_completion(self):
        original = bridge.worker_directory
        cleanup_pending, release = threading.Event(), threading.Event()

        @contextmanager
        def delayed_cleanup():
            with original() as folder:
                yield folder
                cleanup_pending.set()
                if not release.wait(8):
                    raise TimeoutError("test cleanup barrier expired")

        job_id = "6" * 32
        try:
            with mock.patch.object(bridge, "worker_directory", delayed_cleanup):
                pending = self.start(job_id, body={"script": SCRIPT, "jobId": job_id})
                self.assertTrue(cleanup_pending.wait(5))
                code, status = self.request("POST", f"/v1/jobs/{job_id}/cancel", {})
                self.assertEqual(code, 202)
                self.assertEqual(status["state"], "cancelling")
                self.assertTrue(status["workerStopped"])
                self.assertFalse(status["terminal"])
                self.assertFalse(self.server.job_lock.acquire(blocking=False))
                release.set()
                code, reply = pending.result(timeout=8)
            self.assertFalse(reply["success"])
            self.assertEqual(reply["jobStatus"]["state"], "cancelled")
            self.assert_slot_free()
        finally:
            release.set()

    def test_disconnected_generation_can_be_cancelled_over_independent_http(self):
        job_id = "7" * 32
        self.jobs.append(job_id)
        client = HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        try:
            client.request("POST", "/v1/generate", json.dumps({"script": LONG_SCRIPT, "jobId": job_id}),
                           {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
            control = self.running(job_id)
            process = control._process
            client.close()
            code, status = self.request("POST", f"/v1/jobs/{job_id}/cancel", {})
            self.assertEqual(code, 200)
            self.assertEqual(status["state"], "cancelled")
            self.assertTrue(status["workerStopped"])
            self.assertIsNotNone(process.poll())
            self.assert_slot_free()
        finally:
            client.close()

    @unittest.skipUnless(os.name == "nt", "actual Windows job attachment race")
    def test_cancel_during_process_attachment_waits_for_exact_owned_handle(self):
        original = bridge.WindowsJob
        attached, release = threading.Event(), threading.Event()
        children = []

        def delayed_attachment(process, memory):
            job = original(process, memory)
            children.append(process)
            attached.set()
            release.wait(8)
            return job

        job_id = "8" * 32
        try:
            with mock.patch.object(bridge, "WindowsJob", delayed_attachment):
                pending = self.start(job_id)
                self.assertTrue(attached.wait(5))
                cancellation = self.pool.submit(self.request, "POST", f"/v1/jobs/{job_id}/cancel", {})
                self.assertFalse(cancellation.done())
                release.set()
                code, status = cancellation.result(timeout=12)
                code, reply = pending.result(timeout=12)
            self.assertEqual(reply["jobStatus"]["state"], "cancelled")
            self.assertTrue(status["workerStopped"])
            self.assertIsNotNone(children[0].poll())
            self.assert_slot_free()
        finally:
            release.set()

    def test_real_registered_verification_cancel_has_no_pass_or_markers(self):
        with tempfile.TemporaryDirectory(prefix="hongtu-cancel-deck-test-") as folder:
            root = Path(folder)
            layout = db.Layout()
            layout.dbu = 0.001
            layout.create_cell("TOP").shapes(layout.layer(68, 20)).insert(db.Box(0, 0, 200, 400))
            layout.write(str(root / "input.gds"))
            deck = root / "sleep_deck.py"
            deck.write_text("import time\ndef verify_layout(layout, reference, cell, output_dir):\n    time.sleep(30)\n    return {'complete': True, 'passed': True}\n", encoding="utf-8")
            registry = root / "registry.json"
            registry.write_text(json.dumps({"decks": {"cancel-fixture": {"technologyId": "fixture", "kind": "drc",
                "path": deck.name, "sha256": hashlib.sha256(deck.read_bytes()).hexdigest(), "scope": "Temporary cancellation test only"}}}), encoding="utf-8")
            job_id = "3" * 32
            body = {"jobId": job_id, "kind": "drc", "technologyId": "fixture", "deckId": "cancel-fixture",
                    "documentGds": base64.b64encode((root / "input.gds").read_bytes()).decode("ascii")}
            with mock.patch.dict(os.environ, {"HONGTU_TECHNOLOGY_REGISTRY": str(registry)}):
                pending = self.start(job_id, body=body, route="/v1/verify")
                control = self.running(job_id)
                process = control._process
                worker_folder = Path(process.args[-1])
                self.request("POST", f"/v1/jobs/{job_id}/cancel", {})
                code, reply = pending.result(timeout=12)
            self.assertEqual(code, 200)
            self.assertFalse(reply["success"] or reply["complete"] or reply["passed"])
            self.assertEqual(reply["violations"], [])
            self.assertEqual(reply["devices"], [])
            self.assertEqual(reply["jobStatus"]["state"], "cancelled")
            self.assertTrue(reply["jobStatus"]["workerStopped"])
            self.assertIsNotNone(process.poll())
            self.assertFalse(worker_folder.exists())
            self.assert_slot_free()


if __name__ == "__main__":
    unittest.main(verbosity=2)
