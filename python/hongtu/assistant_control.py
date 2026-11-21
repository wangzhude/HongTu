"""Authenticated editor rendezvous and owned assistant cancellation.

No prompts, credentials, documents or model clients survive a completed run.
The native editor owns durable task receipts; this registry owns live handles.
"""
import asyncio
import json
import re
import secrets
import threading
import time

from .jobs import WorkerControl


class AssistantControl:
    def __init__(self):
        self.lock = threading.RLock()
        self.runs = {}
        self.queries = {}

    @staticmethod
    def validate_id(run_id):
        if not isinstance(run_id, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,160}", run_id):
            raise ValueError("invalid assistant run ID")

    def _prune(self):
        now = time.monotonic()
        for key, run in list(self.runs.items()):
            self._snapshot(key, run)
            if run["finished"] and now - run["updated"] > 900:
                del self.runs[key]

    def start(self, run_id):
        self.validate_id(run_id)
        with self.lock:
            self._prune()
            prior = self.runs.get(run_id)
            if prior:
                if prior.get("tombstone"):
                    raise asyncio.CancelledError()
                raise ValueError("assistant run ID already used")
            if len(self.runs) >= 64:
                raise ValueError("assistant run registry full")
            self.runs[run_id] = {"loop": asyncio.get_running_loop(), "task": asyncio.current_task(),
                "worker": None, "modelStopped": False, "cancelled": False, "finished": False,
                "updated": time.monotonic()}

    def attach_worker(self, run_id):
        with self.lock:
            run = self.runs[run_id]
            if run["cancelled"]:
                raise asyncio.CancelledError()
            control = WorkerControl(secrets.token_hex(16))
            run["worker"] = control
            return control

    def finish(self, run_id):
        with self.lock:
            run = self.runs[run_id]
            run.update(modelStopped=True, loop=None, task=None, updated=time.monotonic())
            for key, query in list(self.queries.items()):
                if query["run"] == run_id:
                    del self.queries[key]
            self._snapshot(run_id, run)

    def _snapshot(self, run_id, run):
        worker = run["worker"]
        worker_status = worker.snapshot() if worker is not None else None
        stopped = worker_status is None or (worker_status["terminal"] and worker_status["workerStopped"])
        terminal = run["modelStopped"] and stopped
        run["finished"] = terminal
        if terminal:
            run["worker"] = None
        return {"runId": run_id, "terminal": terminal, "workerStopped": stopped,
                "modelStopped": run["modelStopped"], "cancelRequested": run["cancelled"]}

    def status(self, run_id):
        self.validate_id(run_id)
        with self.lock:
            run = self.runs.get(run_id)
            if run is None:
                raise KeyError("assistant run unavailable")
            return self._snapshot(run_id, run)

    def cancel(self, run_id):
        self.validate_id(run_id)
        with self.lock:
            self._prune()
            run = self.runs.get(run_id)
            if run is None:
                if len(self.runs) >= 64:
                    raise ValueError("assistant run registry full")
                run = {"loop": None, "task": None, "worker": None, "modelStopped": True,
                       "cancelled": True, "finished": True, "tombstone": True, "updated": time.monotonic()}
                self.runs[run_id] = run
            run["cancelled"] = True
            loop, task, worker = run["loop"], run["task"], run["worker"]
        if worker is not None:
            worker.request_cancel(wait_seconds=0)
        if loop is not None and not loop.is_closed() and task is not None and not task.done():
            try:
                loop.call_soon_threadsafe(task.cancel)
            except RuntimeError:
                pass
        return self.status(run_id)

    def open_query(self, run_id):
        with self.lock:
            run = self.runs.get(run_id)
            if run is None or run["cancelled"] or run["modelStopped"]:
                raise ValueError("editor request is no longer active")
            if sum(item["run"] == run_id for item in self.queries.values()) >= 1:
                raise ValueError("an editor query is already pending")
            key = secrets.token_hex(16)
            self.queries[key] = {"run": run_id, "reply": None}
            return key

    def reply(self, key, body):
        if not isinstance(body, dict) or len(json.dumps(body, allow_nan=False).encode("utf-8")) > 96 * 1024:
            raise ValueError("invalid editor reply")
        with self.lock:
            query = self.queries.get(key)
            if query is None or query["reply"] is not None:
                raise KeyError("editor query expired or already answered")
            run = self.runs[query["run"]]
            if run["cancelled"] or run["modelStopped"]:
                raise KeyError("editor query ended")
            query["reply"] = json.loads(json.dumps(body, allow_nan=False))

    async def wait_reply(self, key, timeout=12):
        try:
            async with asyncio.timeout(timeout):
                while True:
                    with self.lock:
                        query = self.queries.get(key)
                        if query is None:
                            raise ValueError("editor request ended")
                        reply = query["reply"]
                    if reply is not None:
                        return reply
                    await asyncio.sleep(0.04)
        finally:
            with self.lock:
                self.queries.pop(key, None)


assistant_control = AssistantControl()
