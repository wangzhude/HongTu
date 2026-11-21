"""Authenticated host companion for layout generation and verification."""
import argparse
import asyncio
from contextlib import contextmanager
import hmac
import json
import os
import queue
from pathlib import Path
import secrets
import re
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .limits import WindowsJob, child_environment, posix_limit
from .jobs import JobRegistry, JobCancelled, JobConflict, JobCapacity, validate_job_id
from .policy import MEMORY_BYTES, MAX_SCRIPT_BYTES, MAX_REQUEST_BYTES, TIMEOUT_SECONDS, validate_request

CONFIG_DIR = Path(os.environ.get("LOCALAPPDATA") or os.environ.get("XDG_DATA_HOME") or (Path.home() / ".local" / "share")) / "HongTu" / "python-bridge"
CONFIG_PATH = CONFIG_DIR / "config.json"
WORKER = Path(__file__).with_name("worker.py")
_REGISTRY_INIT_LOCK = threading.Lock()
ORDINARY_BODY_SECONDS = 20
ARTIFACT_ID_PATTERN = r"^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"
ARTIFACT_ID_RE = re.compile(ARTIFACT_ID_PATTERN)
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def normalize_artifact_id(value: str) -> str:
    """Validate 32-char lowercase hex or 36-char lowercase UUID and normalize to 32-char hex."""
    if not isinstance(value, str) or ARTIFACT_ID_RE.fullmatch(value) is None:
        raise ValueError("invalid artifact ID")
    return value.replace("-", "")


def validate_companion_endpoint(endpoint: str, expected_port: int | None = None) -> tuple[str, str, int]:
    """Allow loopback HTTP or valid host/LAN HTTPS companion endpoints."""
    if not isinstance(endpoint, str) or not endpoint.strip():
        raise ValueError("bridge endpoint is missing")
    cleaned = endpoint.strip().rstrip("/")
    parsed = urlsplit(cleaned)
    if parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
        raise ValueError("bridge endpoint must not contain path, query, fragment or credentials")
    scheme = parsed.scheme.lower()
    host = parsed.hostname or ""
    try:
        port = parsed.port
    except ValueError as exc:
        raise ValueError("bridge endpoint port is invalid") from exc
    if scheme == "http":
        if host.lower() not in _LOOPBACK_HOSTS or port is None:
            raise ValueError("bridge config must use http://127.0.0.1:7865 or https://<host>:<port>")
        if expected_port is not None and port != expected_port:
            raise ValueError("bridge config port does not match endpoint")
    elif scheme == "https":
        if not host or host == "0.0.0.0":
            raise ValueError("bridge HTTPS endpoint requires a valid host")
        if port is None:
            port = 443
        if expected_port is not None and port != expected_port:
            raise ValueError("bridge config port does not match endpoint")
    else:
        raise ValueError("bridge config must use http://127.0.0.1:7865 or https://<host>:<port>")
    if not 1 <= port <= 65535:
        raise ValueError("bridge port must be in 1..65535")
    return scheme, host, port


@contextmanager
def worker_directory():
    directory = tempfile.TemporaryDirectory(prefix="hongtu-python-")
    try:
        yield directory.name
    finally:
        # Antivirus/indexer handles can briefly outlive the already reaped job.
        # Retry only Windows sharing/access errors; permanent cleanup failures
        # remain visible to the caller instead of reporting successful cleanup.
        delays = (0, 0.05, 0.1, 0.2, 0.4, 0.8)
        for attempt, delay in enumerate(delays):
            if delay:
                time.sleep(delay)
            try:
                directory.cleanup()
                break
            except PermissionError as exc:
                if os.name != "nt" or getattr(exc, "winerror", None) not in (5, 32, 33) or attempt == len(delays) - 1:
                    raise


def load_config():
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_PATH.exists():
        config = {"endpoint": "http://127.0.0.1:7865", "port": 7865,
                  "token": secrets.token_urlsafe(32)}
        with open(CONFIG_PATH, "x", encoding="utf-8") as stream:
            json.dump(config, stream)
        if os.name == "nt":
            # Limit the local credential file to its owner and SYSTEM.
            import getpass
            subprocess.run(["icacls", str(CONFIG_PATH), "/inheritance:r", "/grant:r",
                            f"{getpass.getuser()}:(F)", "SYSTEM:(F)"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True,
                           creationflags=subprocess.CREATE_NO_WINDOW)
        else:
            CONFIG_PATH.chmod(0o600)
    config = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    port = config.get("port")
    endpoint = config.get("endpoint")
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("bridge config must specify a valid port")
    scheme, host, _ = validate_companion_endpoint(endpoint, expected_port=port)
    if scheme == "http" and host.lower() not in _LOOPBACK_HOSTS:
        raise ValueError("bridge HTTP config must use a loopback host")
    if scheme == "https":
        if not isinstance(config.get("tlsCert"), str) or not isinstance(config.get("tlsKey"), str):
            raise ValueError("HTTPS bridge config requires tlsCert and tlsKey")
    if not isinstance(config.get("token"), str) or len(config["token"]) < 32:
        raise ValueError("bridge token is missing or too short")
    return config


def generate(script, *, _control=None, **inputs):
    request = {"script": script, **inputs}
    try:
        validate_request(request)
    except (ValueError, TypeError) as exc:
        return {"success": False, "error": str(exc)[:1200]}
    with worker_directory() as folder:
        kwargs = {"stdin": subprocess.PIPE, "stdout": subprocess.DEVNULL,
                  "stderr": subprocess.DEVNULL, "cwd": folder, "env": child_environment()}
        if os.name == "nt":
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
        else:
            kwargs["preexec_fn"] = lambda: posix_limit(MEMORY_BYTES)
        # The Windows venv executable is a redirector, not the worker itself.
        # worker.py bootstraps the trusted repo venv; start its base interpreter
        # directly so kill/wait refer to the exact process executing the script.
        executable = getattr(sys, "_base_executable", sys.executable) if os.name == "nt" else sys.executable
        process = None
        job = None
        try:
            if _control is not None:
                process = _control.spawn(
                    lambda: subprocess.Popen([executable, "-I", str(WORKER), folder], **kwargs),
                    (lambda child: WindowsJob(child, MEMORY_BYTES)) if os.name == "nt" else None)
            else:
                process = subprocess.Popen([executable, "-I", str(WORKER), folder], **kwargs)
                if os.name == "nt":
                    job = WindowsJob(process, MEMORY_BYTES)
            payload = json.dumps(request).encode("utf-8") + b"\n"
            process.communicate(payload, timeout=TIMEOUT_SECONDS)
            result_file = Path(folder) / "result.json"
            if process.returncode != 0 or not result_file.exists():
                return {"success": False, "error": "Python worker stopped (resource limit or native error)"}
            if result_file.stat().st_size > 14 * 1024 * 1024:
                return {"success": False, "error": "Python result exceeds response size limit"}
            return json.loads(result_file.read_text(encoding="utf-8"))
        except subprocess.TimeoutExpired:
            if _control is not None:
                _control.timed_out = True
            return {"success": False, "error": "Python generation exceeded 15 second timeout"}
        except JobCancelled:
            return {"success": False, "error": "Python task cancelled before execution"}
        except Exception:
            return {"success": False, "error": "Python worker could not start with resource limits"}
        finally:
            if _control is not None:
                _control.reap(close_input=True)
            elif process is not None:
                try:
                    if job:
                        job.close()
                finally:
                    if process.poll() is None:
                        process.kill()
                    try:
                        process.wait(timeout=5)
                    finally:
                        if process.stdin is not None:
                            process.stdin.close()


class Handler(BaseHTTPRequestHandler):
    server_version = "HongTuPython/0.3"
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(20)

    def log_message(self, format, *args):
        # Never log headers, bodies, prompts, tokens, paths or generated output.
        return

    def respond(self, status, data):
        raw = json.dumps(data, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)
        except (ConnectionError, TimeoutError):
            # A cancelled native wait must not prevent owned worker cleanup.
            pass
        finally:
            self.close_connection = True

    def authorized(self):
        supplied = self.headers.get("Authorization", "")
        expected = "Bearer " + self.server.token
        return hmac.compare_digest(supplied.encode("utf-8"), expected.encode("utf-8"))

    def job_registry(self):
        # Existing in-process embedders/tests construct the same Handler server;
        # lazily initialize once without changing any assistant SDK route.
        with _REGISTRY_INIT_LOCK:
            if not hasattr(self.server, "jobs"):
                self.server.jobs = JobRegistry()
            return self.server.jobs

    def read_ordinary_body(self, length):
        # Bound the whole upload, not only individual idle reads. A slow upload
        # cannot outlive a pre-cancel tombstone or exhaust handler threads.
        deadline = time.monotonic() + ORDINARY_BODY_SECONDS
        data = bytearray()
        while len(data) < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("ordinary Python request body timed out")
            self.connection.settimeout(remaining)
            chunk = self.rfile.read1(min(65536, length - len(data)))
            if not chunk:
                raise ValueError("ordinary Python request body was truncated")
            data.extend(chunk)
        self.connection.settimeout(20)
        return data

    def ordinary_job_status(self, *, cancel=False):
        if not self.authorized():
            self.respond(401, {"success": False, "error": "Bearer token required"})
            return
        if self.headers.get("Origin"):
            self.respond(403, {"success": False, "error": "browser-origin requests are disabled"})
            return
        route = r"/v1/jobs/([a-f0-9]{32})/cancel" if cancel else r"/v1/jobs/([a-f0-9]{32})"
        match = re.fullmatch(route, self.path)
        if match is None:
            self.respond(400, {"success": False, "error": "invalid job ID or route"})
            return
        try:
            if cancel:
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > 1024 or self.headers.get("Transfer-Encoding"):
                    self.respond(413, {"success": False, "error": "invalid or oversized cancel request"})
                    return
                if json.loads(self.read_ordinary_body(length)) != {}:
                    raise ValueError("cancel request must be an empty object")
                status = self.job_registry().cancel(match[1])
                self.respond(200 if status["terminal"] else 202, status)
            else:
                control = self.job_registry().get(match[1])
                if control is None:
                    self.respond(404, {"success": False, "error": "job unavailable or expired"})
                    return
                self.respond(200, control.snapshot())
        except JobCapacity:
            self.respond(429, {"success": False, "error": "job status capacity is full; retry later"})
        except (ValueError, UnicodeError):
            self.respond(400, {"success": False, "error": "invalid cancel request"})
        except TimeoutError:
            self.respond(408, {"success": False, "error": "cancel request body timed out"})

    def ordinary_job_reply(self, body, result, status):
        if status["state"] in {"cancelled", "cancelling"}:
            error = status.get("error", "Python task cancelled; worker stopped" if status["terminal"] else
                               "Python cancellation is pending; termination is not confirmed")
            if self.path == "/v1/verify":
                from .verification import _empty
                result = _empty(body, error)
            else:
                result = {"success": False, "error": error}
        result["jobId"] = status["jobId"]
        result["jobStatus"] = status
        return result

    def do_GET(self):
        if self.path.startswith("/v1/assistant/runs/"):
            self.assistant_control_request(False)
            return
        if self.path.startswith("/v1/jobs/"):
            self.ordinary_job_status()
            return
        artifact_prefix = "/v1/assistant/artifacts/"
        if self.path.startswith(artifact_prefix):
            if not self.authorized():
                self.respond(401, {"success": False, "error": "Bearer token required"})
                return
            if self.headers.get("Origin"):
                self.respond(403, {"success": False, "error": "browser-origin requests are disabled"})
                return
            raw_artifact_id = self.path[len(artifact_prefix):]
            try:
                artifact_id = normalize_artifact_id(raw_artifact_id)
            except ValueError:
                self.respond(400, {"success": False, "error": "invalid artifact ID"})
                return
            if not self.require_assistant_runtime():
                return
            from .assistant import AssistantError, get_artifact
            try:
                self.respond(200, get_artifact(artifact_id))
            except AssistantError:
                self.respond(404, {"success": False, "error": "artifact unavailable or expired"})
            return
        if self.path != "/health":
            self.respond(404, {"success": False, "error": "not found"})
            return
        if self.headers.get("Authorization") and not self.authorized():
            self.respond(401, {"success": False, "error": "Bearer token required"})
            return
        import klayout.db as db
        from .assistant_dependencies import assistant_runtime_status
        assistant = assistant_runtime_status()
        capabilities = ["generation", "document-input", "selection-input", "parameters",
                        "registered-verification", "job-cancellation-v1", "ports-v1"]
        if assistant["ready"]:
            capabilities.append("assistant-ag-ui")
            capabilities.extend(["assistant-editor-query-v1", "assistant-cancellation-v1", "assistant-diagnostic-v1", "assistant-native-tools-v1"])
        self.respond(200, {"ok": True, "service": "hongtu-python-bridge", "version": "0.3.0",
                           "pid": os.getpid(),
                           "engine": "CPython + klayout.db", "engineVersion": db.__version__,
                           "execution": "host-companion", "restricted": True,
                           "capabilities": capabilities, "assistant": assistant,
                           "timeoutSeconds": TIMEOUT_SECONDS,
                           "maxScriptBytes": MAX_SCRIPT_BYTES})

    def do_POST(self):
        if self.path.startswith(("/v1/assistant/queries/", "/v1/assistant/runs/")):
            self.assistant_control_request(True)
            return
        if self.path.startswith("/v1/jobs/"):
            self.ordinary_job_status(cancel=True)
            return
        if self.path not in {"/v1/generate", "/v1/verify", "/v1/assistant"}:
            self.respond(404, {"success": False, "error": "not found"})
            return
        if not self.authorized():
            self.respond(401, {"success": False, "error": "Bearer token required"})
            return
        if self.headers.get("Origin"):
            self.respond(403, {"success": False, "error": "browser-origin requests are disabled"})
            return
        job_id = None
        try:
            length = int(self.headers.get("Content-Length", "0"))
            max_request = (512 * 1024 if self.path == "/v1/assistant" else
                           46 * 1024 * 1024 if self.path == "/v1/verify" else MAX_REQUEST_BYTES)
            if length <= 0 or length > max_request or self.headers.get("Transfer-Encoding"):
                self.respond(413, {"success": False, "error": "invalid or oversized request"})
                return
            body = json.loads(self.read_ordinary_body(length))
            if self.path != "/v1/assistant" and isinstance(body, dict) and "jobId" in body:
                # Control metadata never enters script policy or worker input.
                job_id = validate_job_id(body.pop("jobId"))
            if self.path == "/v1/assistant":
                if not isinstance(body, dict):
                    raise ValueError("assistant input must be an object")
            elif self.path == "/v1/verify":
                from .verification import validate_verification_request
                validate_verification_request(body)
            else:
                validate_request(body)
        except (ValueError, UnicodeError):
            self.respond(400, {"success": False, "error": "invalid script, layout input or parameters"})
            return
        except TimeoutError:
            self.respond(408, {"success": False, "error": "Python request body timed out"})
            return
        if self.path == "/v1/assistant":
            self.stream_assistant(body)
            return
        control = None
        if job_id is not None:
            try:
                control, fresh = self.job_registry().register(job_id)
            except JobConflict:
                self.respond(409, {"success": False, "error": "jobId has already been used"})
                return
            except JobCapacity:
                self.respond(429, {"success": False, "error": "job status capacity is full; retry later"})
                return
            if not fresh:
                self.respond(200, self.ordinary_job_reply(body, {}, control.snapshot()))
                return
        if not self.server.job_lock.acquire(blocking=False):
            result = {"success": False, "error": "another Python generation is running"}
            if control is not None:
                result = self.ordinary_job_reply(body, result, control.complete(False, lambda: None))
            self.respond(429, result)
            return
        result = {"success": False, "error": "Python worker could not complete safely"}
        cleanup_failed = False
        try:
            if self.path == "/v1/verify":
                from .verification import run_verification
                result = run_verification(body, _control=control) if control is not None else run_verification(body)
            else:
                result = generate(**body, _control=control) if control is not None else generate(**body)
            if not isinstance(result, dict) or type(result.get("success")) is not bool:
                raise ValueError("worker did not return a structured result")
        except Exception:
            cleanup_failed = True
            if self.path == "/v1/verify":
                from .verification import _empty
                result = _empty(body, "Python worker could not complete safely")
            else:
                result = {"success": False, "error": "Python worker could not complete safely"}
        finally:
            if control is None:
                self.server.job_lock.release()
            else:
                status = control.complete(result.get("success") is True, self.server.job_lock.release,
                                          cleanup_failed=cleanup_failed)
                result = self.ordinary_job_reply(body, result, status)
        self.respond(200, result)

    def require_assistant_runtime(self):
        from .assistant_dependencies import assistant_runtime_status
        status = assistant_runtime_status()
        if not status["ready"]:
            self.respond(503, {"success": False, "code": status["code"], "error": status["error"]})
            return False
        return True

    def assistant_control_request(self, post):
        if not self.authorized():
            self.respond(401, {"success": False, "error": "Bearer token required"})
            return
        if self.headers.get("Origin"):
            self.respond(403, {"success": False, "error": "browser-origin requests are disabled"})
            return
        from .assistant_control import assistant_control
        query = re.fullmatch(r"/v1/assistant/queries/([a-f0-9]{32})", self.path) if post else None
        run = re.fullmatch(r"/v1/assistant/runs/([A-Za-z0-9_.:-]{1,160})" + (r"/cancel" if post else ""), self.path)
        if query is None and run is None:
            self.respond(404, {"success": False, "error": "not found"})
            return
        try:
            body = {}
            if post:
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > 96 * 1024 or self.headers.get("Transfer-Encoding"):
                    self.respond(413, {"success": False, "error": "invalid editor control body"})
                    return
                body = json.loads(self.read_ordinary_body(length))
            if query is not None:
                assistant_control.reply(query[1], body)
                self.respond(200, {"success": True})
            else:
                if post and body != {}:
                    raise ValueError("cancel request must be empty")
                result = assistant_control.cancel(run[1]) if post else assistant_control.status(run[1])
                self.respond(200, result)
        except KeyError:
            self.respond(404, {"success": False, "error": "assistant request expired or unavailable"})
        except (ValueError, UnicodeError):
            self.respond(400, {"success": False, "error": "invalid assistant control request"})
        except TimeoutError:
            self.respond(408, {"success": False, "error": "assistant control request timed out"})

    def stream_assistant(self, body):
        """Forward official AG-UI events; HTTP owns only framing/lifetime.

        The bounded producer is the upstream SDK, not another agent loop. A
        heartbeat detects disconnected native clients while the model thinks.
        Cancellation reaches its asyncio task and cannot publish late artifacts.
        """
        if not self.require_assistant_runtime():
            return
        from ag_ui.core import RunErrorEvent
        from ag_ui.encoder import EventEncoder
        from .assistant import encoded_stream

        slots = self.server.assistant_slots
        if not slots.acquire(blocking=False):
            self.respond(429, {"success": False, "error": "assistant capacity is busy"})
            return
        self.connection.settimeout(10)
        self.close_connection = True
        output = queue.Queue(maxsize=32)
        stopped = threading.Event()
        ready = threading.Event()
        owner = {}
        end = object()

        async def publish(value):
            while not stopped.is_set():
                try:
                    output.put_nowait(value)
                    return
                except queue.Full:
                    await asyncio.sleep(0.05)
            raise asyncio.CancelledError()

        async def produce():
            owner["loop"] = asyncio.get_running_loop()
            owner["task"] = asyncio.current_task()
            ready.set()
            if stopped.is_set():
                return
            try:
                async for event in encoded_stream(body):
                    await publish(event.encode("utf-8"))
            except asyncio.CancelledError:
                pass
            except Exception:
                # Never expose validation input, model keys or SDK tracebacks.
                await publish(EventEncoder().encode(RunErrorEvent(
                    message="助手运行失败，请检查模型与伴随服务配置。",
                    code="HONGTU_ASSISTANT_ERROR")).encode("utf-8"))
            finally:
                if not stopped.is_set():
                    await publish(end)

        def worker():
            try:
                asyncio.run(produce())
            except asyncio.CancelledError:
                pass
            finally:
                slots.release()

        thread = threading.Thread(target=worker, name="hongtu-agui-stream", daemon=True)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            thread.start()
            started = time.monotonic()
            sent = 0
            while time.monotonic() - started < 185:
                try:
                    value = output.get(timeout=5)
                except queue.Empty:
                    value = b": hongtu heartbeat\n\n"
                if value is end:
                    break
                sent += len(value)
                if sent > 8 * 1024 * 1024:
                    break
                self.wfile.write(value)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionError, TimeoutError, OSError):
            pass
        finally:
            stopped.set()
            if not thread.ident:
                slots.release()
            elif ready.is_set():
                loop, task = owner["loop"], owner["task"]
                if not loop.is_closed() and not task.done():
                    try:
                        loop.call_soon_threadsafe(task.cancel)
                    except RuntimeError:
                        pass
            # The worker releases its slot only after owned clients/jobs close.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--init-config", action="store_true")
    parser.add_argument("--port", type=int, default=None,
                        help="alternate port for an isolated local or LAN HTTPS bridge instance")
    parser.add_argument("--host", default=None,
                        help="bind address (non-loopback requires --tls-cert and --tls-key)")
    parser.add_argument("--tls-cert", default=None, help="PEM certificate file for HTTPS companion mode")
    parser.add_argument("--tls-key", default=None, help="PEM private key file for HTTPS companion mode")
    args = parser.parse_args()
    config = load_config()
    if args.init_config:
        print(f"Configuration ready: {CONFIG_PATH}")
        return
    port = config["port"] if args.port is None else args.port
    if not 1 <= port <= 65535:
        parser.error("port must be in 1..65535")
    cert_path = args.tls_cert or config.get("tlsCert")
    key_path = args.tls_key or config.get("tlsKey")
    bind_host = args.host or (urlsplit(config["endpoint"]).hostname or "127.0.0.1")
    if (cert_path is None) != (key_path is None):
        parser.error("--tls-cert and --tls-key must be supplied together")
    if bind_host.lower() not in _LOOPBACK_HOSTS and not cert_path:
        parser.error("non-loopback companion bind requires HTTPS (--tls-cert and --tls-key)")
    server = ThreadingHTTPServer((bind_host, port), Handler)
    if cert_path and key_path:
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
        tls_context.load_cert_chain(certfile=cert_path, keyfile=key_path)
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    server.daemon_threads = True
    server.token = config["token"]
    server.job_lock = threading.Lock()
    server.jobs = JobRegistry()
    server.assistant_slots = threading.BoundedSemaphore(2)
    os.environ.setdefault("PYDANTIC_AI_NO_BANNER", "1")
    from .assistant_dependencies import assistant_runtime_status
    if assistant_runtime_status()["ready"]:
        from .assistant import enable_artifact_persistence
        enable_artifact_persistence()
    scheme = "https" if cert_path else "http"
    print(f"HongTu Python bridge listening on {scheme}://{bind_host}:{port} (host companion)", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
