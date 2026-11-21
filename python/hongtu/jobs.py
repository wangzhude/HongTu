"""Bounded ownership and cancellation of ordinary HTTP Python workers.

Only supervisors hold process handles. IDs never grant script capabilities and
the registry stores no source, credentials, layout data, result files or PIDs.
Assistant SDK runs deliberately do not register in this ordinary-job registry.
"""
from __future__ import annotations

import re
import threading
import time

TERMINAL = frozenset({"cancelled", "succeeded", "failed", "timed_out"})
MAX_JOBS = 256
RETENTION_SECONDS = 300


def validate_job_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{32}", value):
        raise ValueError("jobId must be 32 lowercase hexadecimal characters")
    return value


class JobCancelled(Exception):
    pass


class JobConflict(ValueError):
    pass


class JobCapacity(ValueError):
    pass


class WorkerControl:
    def __init__(self, job_id, clock=time.monotonic, *, tombstone=False):
        self.job_id = validate_job_id(job_id)
        self._clock = clock
        self._lock = threading.RLock()
        self._done = threading.Event()
        self._process = None
        self._resource_job = None
        self._stop_error = False
        self._cancel_requested = tombstone
        self._state = "cancelled" if tombstone else "starting"
        self._worker_stopped = True
        self._error = ""
        self.finished_at = clock() if tombstone else None
        self.tombstone = tombstone
        self.timed_out = False
        if tombstone:
            self._done.set()

    def snapshot(self):
        with self._lock:
            result = {"jobId": self.job_id, "state": self._state,
                      "terminal": self._done.is_set(), "workerStopped": self._worker_stopped}
            if self._error:
                result["error"] = self._error
            return result

    def spawn(self, factory, resource_factory=None):
        # The registration exists before this lock can create a process. A cancel
        # arriving during launch waits until the exact handle and job are owned.
        with self._lock:
            if self._cancel_requested or self._done.is_set():
                raise JobCancelled("Python task was cancelled before execution")
            self._process = factory()
            self._worker_stopped = False
            try:
                if resource_factory is not None:
                    self._resource_job = resource_factory(self._process)
            except Exception:
                self.reap(close_input=True)
                raise
            self._state = "running"
            return self._process

    def reap(self, *, close_input=False):
        # Concurrent cancel and producer-finally cleanup share this lock. Never
        # kill by a caller-supplied PID, process name or a system-wide command.
        with self._lock:
            process = self._process
            if process is None:
                return
            failure = None
            try:
                if self._resource_job is not None:
                    try:
                        self._resource_job.close()
                    except Exception as exc:
                        self._stop_error = True
                        failure = exc
                    finally:
                        if self._resource_job.handle is None:
                            self._resource_job = None
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
            except Exception as exc:
                self._stop_error = True
                failure = exc
            finally:
                if close_input and process.stdin is not None:
                    try:
                        process.stdin.close()
                    except OSError:
                        pass
            self._worker_stopped = process.poll() is not None and not self._stop_error
            if failure is not None:
                raise RuntimeError("owned Python worker termination could not be confirmed") from None

    def request_cancel(self, wait_seconds=1):
        with self._lock:
            if self._done.is_set():
                return self.snapshot()
            self._cancel_requested = True
            self._state = "cancelling"
        try:
            self.reap()
        except RuntimeError:
            with self._lock:
                self._error = "Owned worker termination is not confirmed"
        # The producing handler publishes terminal state after directory cleanup
        # and releasing the ordinary generation slot, never just after kill().
        self._done.wait(wait_seconds)
        return self.snapshot()

    def complete(self, success, release_slot, *, cleanup_failed=False):
        with self._lock:
            if self._done.is_set():
                raise RuntimeError("ordinary Python job completed twice")
            if not self._worker_stopped:
                # Do not admit another worker while termination is unconfirmed.
                self._state = "cancelling"
                self._error = "Owned worker termination is not confirmed"
                return self.snapshot()
            release_slot()
            if cleanup_failed:
                self._state = "failed"
                self._error = "Python task cleanup failed; worker stopped"
            elif self._cancel_requested:
                self._state = "cancelled"
                self._error = "Python task cancelled; worker stopped"
            elif self.timed_out:
                self._state = "timed_out"
                self._error = "Python task exceeded its execution time limit"
            elif success:
                self._state = "succeeded"
            else:
                self._state = "failed"
                self._error = "Python task failed"
            # Popen.communicate retains its input bytes. Terminal status must
            # not retain a script/layout payload through the process object.
            self._process = None
            self._resource_job = None
            self.finished_at = self._clock()
            self._done.set()
            return self.snapshot()


class JobRegistry:
    def __init__(self, *, capacity=MAX_JOBS, retention=RETENTION_SECONDS, clock=time.monotonic):
        self._jobs = {}
        self._lock = threading.Lock()
        self._capacity = capacity
        self._retention = retention
        self._clock = clock

    def _prune(self):
        deadline = self._clock() - self._retention
        self._jobs = {key: value for key, value in self._jobs.items()
                      if value.finished_at is None or value.finished_at > deadline}

    def _room(self):
        self._prune()
        if len(self._jobs) >= self._capacity:
            raise JobCapacity("ordinary Python job status capacity is full; retry later")

    def register(self, job_id):
        validate_job_id(job_id)
        with self._lock:
            self._prune()
            previous = self._jobs.get(job_id)
            if previous is not None:
                if previous.tombstone:
                    return previous, False
                raise JobConflict("jobId has already been used")
            self._room()
            control = WorkerControl(job_id, self._clock)
            self._jobs[job_id] = control
            return control, True

    def get(self, job_id):
        validate_job_id(job_id)
        with self._lock:
            self._prune()
            return self._jobs.get(job_id)

    def cancel(self, job_id):
        validate_job_id(job_id)
        with self._lock:
            self._prune()
            control = self._jobs.get(job_id)
            if control is None:
                self._room()
                # Covers a cancel request arriving before the generate POST has
                # finished upload/validation. No late request can start this ID.
                control = WorkerControl(job_id, self._clock, tombstone=True)
                self._jobs[job_id] = control
        return control.request_cancel()
