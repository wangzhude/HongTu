"""Real SDK/editor rendezvous and persistence; model responses are explicit fixtures."""
import asyncio
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from hongtu import assistant as mod
from hongtu.assistant_control import AssistantControl
from test_assistant import request_payload, parse_sse, tool_model
import test_assistant_http as http_fixture


class ControlTests(unittest.IsolatedAsyncioTestCase):
    async def test_reply_is_owned_once_and_removed_after_consumption(self):
        control = AssistantControl()
        control.start("reply")
        key = control.open_query("reply")
        with self.assertRaises(ValueError):
            control.open_query("reply")
        data = {"items": [{"x": 42}]}
        control.reply(key, data)
        data["items"][0]["x"] = -1
        with self.assertRaises(KeyError):
            control.reply(key, {})
        self.assertEqual(await control.wait_reply(key), {"items": [{"x": 42}]})
        self.assertEqual(control.queries, {})
        control.finish("reply")
        self.assertTrue(control.status("reply")["terminal"])
        with self.assertRaises(ValueError):
            control.start("reply")

    async def test_timeout_and_oversized_reply_do_not_leak_queries(self):
        control = AssistantControl()
        control.start("timeout")
        key = control.open_query("timeout")
        with self.assertRaises(ValueError):
            control.reply(key, {"body": "文" * 100000})
        with self.assertRaises(TimeoutError):
            await control.wait_reply(key, timeout=0.01)
        self.assertEqual(control.queries, {})
        control.finish("timeout")

    async def test_precancel_never_starts_and_unconfirmed_worker_is_not_terminal(self):
        control = AssistantControl()
        self.assertTrue(control.cancel("pre")["terminal"])
        with self.assertRaises(asyncio.CancelledError):
            control.start("pre")
        control.start("worker")
        worker = control.attach_worker("worker")
        control.finish("worker")
        self.assertFalse(control.status("worker")["terminal"])
        worker.complete(True, lambda: None)
        self.assertTrue(control.status("worker")["terminal"])
        self.assertIsNone(control.runs["worker"]["worker"])

    async def test_cancel_interrupts_owned_task_and_rejects_late_editor_reply(self):
        control = AssistantControl()
        started = asyncio.Event()
        keys = []
        async def owned():
            control.start("cancel")
            keys.append(control.open_query("cancel"))
            started.set()
            try:
                await control.wait_reply(keys[0])
            finally:
                control.finish("cancel")
        task = asyncio.create_task(owned())
        await started.wait()
        first = control.cancel("cancel")
        self.assertFalse(first["terminal"])
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertTrue(control.status("cancel")["modelStopped"])
        self.assertTrue(control.status("cancel")["workerStopped"])
        with self.assertRaises(KeyError):
            control.reply(keys[0], {})


class SDKWorkbenchTests(unittest.IsolatedAsyncioTestCase):
    async def test_actual_assistant_worker_cancellation_reaps_process_and_releases_capacity(self):
        from test_job_cancel import LONG_SCRIPT
        control = AssistantControl()
        started = asyncio.Event()
        worker_future = None
        async def owned():
            nonlocal worker_future
            control.start('real-worker')
            worker_future = asyncio.create_task(asyncio.to_thread(mod._generate_worker, LONG_SCRIPT, '', 'real-worker'))
            started.set()
            try: await asyncio.shield(worker_future)
            finally: control.finish('real-worker')
        with patch.object(mod, 'assistant_control', control):
            task = asyncio.create_task(owned())
            await started.wait()
            for _ in range(300):
                worker = control.runs['real-worker']['worker']
                if worker is not None and not worker.snapshot()['workerStopped']: break
                await asyncio.sleep(.01)
            self.assertIsNotNone(worker)
            self.assertFalse(worker.snapshot()['workerStopped'])
            control.cancel('real-worker')
            with self.assertRaises(asyncio.CancelledError): await task
            await asyncio.wait_for(worker_future, 10)
            self.assertTrue(control.status('real-worker')['terminal'])
            self.assertTrue(control.status('real-worker')['workerStopped'])
            self.assertTrue(mod._worker_lock.acquire(blocking=False))
            mod._worker_lock.release()

    async def stream(self, model, payload, reply=None):
        class Client:
            closed = False
            async def close(self): self.closed = True
        client, control, chunks = Client(), AssistantControl(), []
        with patch.object(mod, "assistant_control", control), patch.object(mod, "_model_client", return_value=(model, client, {})):
            async for chunk in mod.encoded_stream(payload):
                chunks.append(chunk)
                for event in parse_sse([chunk]):
                    if event.get("name") == "hongtu.editor_query":
                        self.assertIsNotNone(reply)
                        control.reply(event["value"]["queryId"], reply)
        self.assertTrue(client.closed)
        self.assertTrue(control.status(payload["runId"])["terminal"])
        return parse_sse(chunks)

    async def test_live_query_returns_measured_units_revision_and_truncation_through_sdk(self):
        payload = request_payload("查询当前Cell图形")
        payload["forwardedProps"]["editorProtocol"] = "hongtu-editor-query/v1"
        events = await self.stream(tool_model("query_editor", {"query": {"kind": "shapes", "limit": 1}}), payload,
            {"success": True, "coordinateUnit": "nm", "documentRevision": 7, "total": 2,
             "truncated": True, "nextOffset": 1, "items": [{"data": {"id": 42, "x": 12.5}}]})
        result = next(e["content"] for e in events if e["type"] == "TOOL_CALL_RESULT")
        data = json.loads(result)
        self.assertEqual(data["documentRevision"], 7)
        self.assertEqual(data["coordinateUnit"], "nm")
        self.assertEqual(data["items"][0]["data"]["id"], 42)
        self.assertTrue(data["truncated"])
        self.assertEqual(events[-1]["type"], "RUN_FINISHED")

    async def test_query_without_sharing_never_emits_editor_request(self):
        payload = request_payload("解释版图")
        payload["forwardedProps"].update(editorProtocol="hongtu-editor-query/v1")
        payload["forwardedProps"]["layoutContext"]["layoutContextIncluded"] = False
        events = await self.stream(tool_model("query_editor", {"query": {"kind": "cells"}}), payload)
        self.assertFalse(any(e.get("name") == "hongtu.editor_query" for e in events))

    async def test_workflow_is_pending_and_readonly_task_cannot_open_it(self):
        for prompt, allowed in (("对选择图形执行合并", True), ("解释如何合并图形", False)):
            payload = request_payload(prompt)
            payload["forwardedProps"]["editorProtocol"] = "hongtu-editor-query/v1"
            events = await self.stream(tool_model("prepare_native_workflow", {"workflow": "boolean_union", "summary": "合并当前选区"}), payload)
            workflows = [e for e in events if e.get("name") == "hongtu.workflow"]
            self.assertEqual(len(workflows), int(allowed))
            self.assertFalse(any(e.get("name") in ("hongtu.commands", "hongtu.artifact") for e in events))

    async def test_diagnostic_requires_actual_tool_call_not_model_claim(self):
        from pydantic_ai.models.function import FunctionModel
        async def claim(messages, info): yield "工具诊断已经通过"
        for model, expected in ((tool_model("check_tool_protocol", {}), True), (FunctionModel(stream_function=claim), False)):
            payload = request_payload("只读工具诊断", tabs=0)
            payload["forwardedProps"]["runKind"] = "diagnostic"
            events = await self.stream(model, payload)
            probe = next(e for e in events if e.get("name") == "hongtu.diagnostic")
            self.assertEqual(probe["value"]["toolCallPassed"], expected)


class PersistentArtifactTests(unittest.TestCase):
    def test_restart_returns_identical_owned_artifact_and_isolation(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            cache = mod.ArtifactCache(directory)
            key = cache.put({"success": True, "gdsBase64": "fixture", "script": "bounded", "originalRequest": "创建"})
            restarted = mod.ArtifactCache(directory)
            self.assertEqual(restarted.get(key), cache.get(key))
            value = restarted.get(key); value["script"] = "changed"
            self.assertEqual(restarted.get(key)["script"], "bounded")
            self.assertFalse(list(directory.glob("*.tmp")))

    def test_expired_and_evicted_owned_records_are_removed_unrelated_files_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            unrelated = directory / "notes.json"; unrelated.write_text("{}")
            expired = directory / ("0" * 32 + ".json")
            expired.write_text(json.dumps({"version": 1, "expiresAt": 0, "reply": {}}))
            cache = mod.ArtifactCache(directory)
            keys = [cache.put({"index": n}) for n in range(mod.MAX_ARTIFACTS + 1)]
            self.assertFalse(expired.exists())
            self.assertTrue(unrelated.exists())
            self.assertEqual(len(list(directory.glob("*.json"))), mod.MAX_ARTIFACTS + 1)
            with self.assertRaises(mod.AssistantError): cache.get(keys[0])
            self.assertEqual(mod.ArtifactCache(directory).get(keys[-1])["index"], mod.MAX_ARTIFACTS)

    def test_failed_save_preserves_existing_artifact(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = mod.ArtifactCache(Path(folder))
            key = cache.put({"existing": True})
            with patch("hongtu.assistant.os.fsync", side_effect=OSError("disk full")):
                with self.assertRaises(mod.AssistantError): cache.put({"new": True})
            self.assertTrue(cache.get(key)["existing"])


class ControlHTTPTests(http_fixture.AssistantHTTP):
    # Existing HTTP regressions run in their own module; inherit just helpers.
    def test_control_auth_origin_and_precancel_status(self):
        import uuid
        path = "/v1/assistant/runs/" + uuid.uuid4().hex
        self.assertEqual(self.request(path=path + "/cancel", headers={"Authorization": ""})[0], 401)
        self.assertEqual(self.request(path=path + "/cancel", headers={"Origin": "https://invalid.test"})[0], 403)
        status, _, raw = self.request(path=path + "/cancel")
        self.assertEqual(status, 200)
        self.assertTrue(json.loads(raw)["terminal"])
        self.assertEqual(self.request("GET", path)[0], 200)
        self.assertEqual(self.request(path="/v1/assistant/queries/" + "f" * 32)[0], 404)


# Avoid re-running inherited test methods while keeping the HTTP fixture helpers.
for _name in list(http_fixture.AssistantHTTP.__dict__):
    if _name.startswith("test_"):
        setattr(ControlHTTPTests, _name, None)

if __name__ == "__main__": unittest.main()
