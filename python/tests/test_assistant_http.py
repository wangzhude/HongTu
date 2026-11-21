"""Ephemeral real HTTP Handler integration; only the SDK producer is replaced.

No live model, production bridge port, device, or geometry execution is used.
Events are encoded by the installed official AG-UI EventEncoder.
"""
import asyncio
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import socket
import struct
import threading
import time
import unittest
from unittest.mock import patch

from ag_ui.core import RunStartedEvent, RunFinishedEvent, TextMessageStartEvent, TextMessageContentEvent, TextMessageEndEvent
from ag_ui.encoder import EventEncoder
from hongtu import assistant, bridge
from hongtu.bridge import ARTIFACT_ID_PATTERN, Handler, normalize_artifact_id

TOKEN = "ephemeral-assistant-test-token-only"


def events():
    return [RunStartedEvent(thread_id="http-thread", run_id="http-run"),
            TextMessageStartEvent(message_id="reply", role="assistant"),
            TextMessageContentEvent(message_id="reply", delta="实际HTTP逐事件正文"),
            TextMessageEndEvent(message_id="reply"),
            RunFinishedEvent(thread_id="http-thread", run_id="http-run")]


def decode_sse(raw):
    return [json.loads(line[6:]) for line in raw.decode("utf-8").splitlines() if line.startswith("data: ")]


class AssistantHTTP(unittest.TestCase):
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

    def connect(self):
        return HTTPConnection("127.0.0.1", self.port, timeout=10)

    def request(self, method="POST", path="/v1/assistant", body=b"{}", headers=None):
        merged = {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"}
        if headers:
            merged.update(headers)
        connection = self.connect()
        try:
            connection.request(method, path, body=body if method == "POST" else None, headers=merged)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def assert_slot_available(self):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if self.server.assistant_slots.acquire(blocking=False):
                self.server.assistant_slots.release()
                return
            time.sleep(0.01)
        self.fail("assistant slot was not released")

    def test_post_requires_exact_bearer_and_rejects_browser_origin_before_producer(self):
        async def forbidden(payload):
            self.fail("unauthorized input reached SDK")
            yield ""
        with patch.object(assistant, "encoded_stream", forbidden):
            for auth in ("", "Bearer wrong", "bearer " + TOKEN):
                status, _, _ = self.request(headers={"Authorization": auth})
                self.assertEqual(status, 401)
            status, _, _ = self.request(headers={"Origin": "https://untrusted.invalid"})
            self.assertEqual(status, 403)
        self.assert_slot_available()

    def test_artifact_get_requires_auth_origin_and_strict_identifier(self):
        path = "/v1/assistant/artifacts/" + "a" * 32
        self.assertEqual(self.request("GET", path, headers={"Authorization": ""})[0], 401)
        self.assertEqual(self.request("GET", path, headers={"Origin": "https://untrusted.invalid"})[0], 403)
        for bad in ("../x", "A" * 32, "a" * 31, "a" * 32 + "?key=x",
                    "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "a" * 8 + "-" + "a" * 24):
            self.assertEqual(self.request("GET", "/v1/assistant/artifacts/" + bad)[0], 400)

    def test_missing_artifact_returns_404_and_existing_get_accepts_hex32_and_uuid36(self):
        status, _, raw = self.request("GET", "/v1/assistant/artifacts/" + "0" * 32)
        self.assertEqual(status, 404)
        self.assertFalse(json.loads(raw)["success"])
        key = assistant._artifacts.put({"success": True, "script": "fixture", "gdsBase64": "bounded-fixture"})
        status, headers, raw = self.request("GET", "/v1/assistant/artifacts/" + key)
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(json.loads(raw)["artifactId"], key)
        hyphenated = f"{key[:8]}-{key[8:12]}-{key[12:16]}-{key[16:20]}-{key[20:]}"
        self.assertEqual(normalize_artifact_id(hyphenated), key)
        status_uuid, _, raw_uuid = self.request("GET", "/v1/assistant/artifacts/" + hyphenated)
        self.assertEqual(status_uuid, 200)
        self.assertEqual(json.loads(raw_uuid)["artifactId"], key)

    def test_artifact_id_regex_matches_arkts_service_contract(self):
        ets_path = Path(__file__).resolve().parents[2] / "entry/src/main/ets/services/PythonBridgeService.ets"
        if not ets_path.exists():
            ets_path = Path(__file__).resolve().parents[3] / "entry/src/main/ets/services/PythonBridgeService.ets"
        source = ets_path.read_text(encoding="utf-8")
        match = re.search(r"PYTHON_ARTIFACT_ID_REGEX:\s*RegExp\s*=\s*\n?\s*/([^/]+)/;", source)
        self.assertIsNotNone(match, "PYTHON_ARTIFACT_ID_REGEX must be exported in PythonBridgeService.ets")
        self.assertEqual(match.group(1), ARTIFACT_ID_PATTERN)

    def test_slow_assistant_body_enforces_ordinary_deadline_without_holding_slot(self):
        with patch.object(bridge, "ORDINARY_BODY_SECONDS", 0.15):
            raw_sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
            try:
                headers = (
                    "POST /v1/assistant HTTP/1.1\r\n"
                    "Host: 127.0.0.1\r\n"
                    f"Authorization: Bearer {TOKEN}\r\n"
                    "Content-Type: application/json\r\n"
                    "Content-Length: 64\r\n"
                    "\r\n"
                    "{\""
                ).encode("ascii")
                raw_sock.sendall(headers)
                # Drip slowly past ORDINARY_BODY_SECONDS to confirm total deadline enforcement.
                time.sleep(0.25)
                reply = raw_sock.recv(4096)
            finally:
                raw_sock.close()
        self.assertIn(b"408", reply.splitlines()[0])
        self.assert_slot_available()

    def test_invalid_json_non_object_and_invalid_length_are_rejected(self):
        for body in (b"{", b"[]", b"null"):
            self.assertEqual(self.request(body=body)[0], 400)
        self.assertEqual(self.request(body=b"")[0], 413)
        self.assertEqual(self.request(body=b"{}", headers={"Content-Length": "bad"})[0], 400)
        self.assertEqual(self.request(body=b"{}", headers={"Transfer-Encoding": "chunked"})[0], 413)

    def test_oversized_body_header_is_rejected_without_reading_body(self):
        connection = self.connect()
        try:
            connection.putrequest("POST", "/v1/assistant")
            connection.putheader("Authorization", "Bearer " + TOKEN)
            connection.putheader("Content-Length", str(512 * 1024 + 1))
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 413)
            response.read()
        finally:
            connection.close()

    def test_completed_sse_uses_official_events_and_releases_slot(self):
        seen = []
        async def fixture(payload):
            seen.append(payload)
            for event in events():
                yield EventEncoder().encode(event)
        with patch.object(assistant, "encoded_stream", fixture):
            status, headers, raw = self.request(body=b'{"fixture":true}')
        self.assertEqual(status, 200)
        self.assertIn("text/event-stream", headers["Content-Type"])
        self.assertEqual(headers["Connection"], "close")
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(seen, [{"fixture": True}])
        self.assertEqual([item["type"] for item in decode_sse(raw)], [item.type.value for item in events()])
        self.assert_slot_available()

    def test_producer_validation_failure_is_redacted_official_run_error(self):
        async def fixture(payload):
            raise ValueError("secret-key http://private-endpoint D:\\private\\path")
            yield ""
        with patch.object(assistant, "encoded_stream", fixture):
            status, _, raw = self.request()
        self.assertEqual(status, 200)
        decoded = decode_sse(raw)
        self.assertEqual(decoded[0]["type"], "RUN_ERROR")
        self.assertNotIn(b"secret-key", raw)
        self.assertNotIn(b"private", raw)
        self.assert_slot_available()

    def test_concurrent_request_gets_429_until_first_generator_finishes(self):
        release = threading.Event()
        started = threading.Event()
        async def fixture(payload):
            started.set()
            yield EventEncoder().encode(events()[0])
            while not release.is_set():
                await asyncio.sleep(0.01)
            yield EventEncoder().encode(events()[-1])
        with patch.object(assistant, "encoded_stream", fixture):
            connection = self.connect()
            try:
                connection.request("POST", "/v1/assistant", body=b"{}", headers={"Authorization": "Bearer " + TOKEN})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertTrue(started.wait(2))
                self.assertEqual(self.request()[0], 429)
                release.set()
                self.assertEqual(decode_sse(response.read())[-1]["type"], "RUN_FINISHED")
            finally:
                release.set()
                connection.close()
        self.assert_slot_available()

    def test_idle_stream_sends_heartbeat_without_corrupting_official_sse(self):
        async def fixture(payload):
            yield EventEncoder().encode(events()[0])
            await asyncio.sleep(5.1)
            yield EventEncoder().encode(events()[-1])
        with patch.object(assistant, "encoded_stream", fixture):
            status, _, raw = self.request()
        self.assertEqual(status, 200)
        self.assertIn(b": hongtu heartbeat\n\n", raw)
        self.assertEqual([event["type"] for event in decode_sse(raw)], ["RUN_STARTED", "RUN_FINISHED"])
        self.assert_slot_available()

    def test_disconnect_cancels_owned_async_generator_and_releases_slot(self):
        cancelled = threading.Event()
        async def fixture(payload):
            try:
                yield EventEncoder().encode(events()[0])
                await asyncio.sleep(300)
                self.fail("disconnected stream kept running")
            finally:
                cancelled.set()
        with patch.object(assistant, "encoded_stream", fixture):
            connection = self.connect()
            connection.request("POST", "/v1/assistant", body=b"{}", headers={"Authorization": "Bearer " + TOKEN})
            live_socket = connection.sock
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertTrue(response.readline().startswith(b"data: "))
            # Reset the TCP connection so the next real heartbeat fails reliably.
            live_socket.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("hh" if os.name == "nt" else "ii", 1, 0))
            response.close()
            connection.close()
            self.assertTrue(cancelled.wait(8), "SDK generator did not receive disconnect cancellation")
        self.assert_slot_available()


if __name__ == "__main__":
    unittest.main()
