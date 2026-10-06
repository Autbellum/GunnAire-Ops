#!/usr/bin/env python3
"""Explicitly invoked outbound-only Mac worker; no service, listener or cloud model."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import hashlib
import http.client
import json
import math
import multiprocessing
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Backend.local_ai_gateway import GatewayError, LocalAIGateway, Settings
from LocalAI.local_ai import Config, ModelRole, load_policy

MODEL = "gunnaire-coder:ops"
DIGEST = "81a62afe947e7718a8f075fd78f1e9a98597e1bf4d521c5a770eb7531c47977b"
OLLAMA = "http://127.0.0.1:11434"
SHARED_LOCK = Path("/Users/gunnaire/Documents/GunnAireLocalQA/runs/.lock")
BODY_LIMIT = 131_072
MAX_JOBS = 4096
PATHS = {"heartbeat", "claim", "complete"}
FAILURES = {"unavailable", "busy", "request_failed", "invalid_model_response"}


class WorkerError(RuntimeError):
    """Messages are fixed codes, never remote payloads or exception text."""


def decode(data):
    def pairs(values):
        out = {}
        for key, value in values:
            if key in out:
                raise WorkerError("invalid_json")
            out[key] = value
        return out
    def invalid(_):
        raise WorkerError("invalid_json")
    def finite_float(value):
        number = float(value)
        if not math.isfinite(number):
            raise WorkerError("invalid_json")
        return number
    try:
        result = json.loads(data, object_pairs_hook=pairs, parse_constant=invalid, parse_float=finite_float)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise WorkerError("invalid_json") from exc
    if not isinstance(result, dict):
        raise WorkerError("invalid_json")
    return result


def regular(fd, *, private=True):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        raise WorkerError("unsafe_file")
    if private and info.st_mode & 0o077:
        raise WorkerError("unsafe_file_permissions")


def read_private(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        regular(fd)
        data = os.read(fd, limit + 1)
        if len(data) > limit or os.read(fd, 1):
            raise WorkerError("file_too_large")
        return data
    finally:
        os.close(fd)


def private_parent(path):
    parent = Path(path).parent
    info = parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise WorkerError("unsafe_private_directory")


def origin(value, *, allow_fixture=False):
    if not isinstance(value, str) or len(value) > 512 or any(ord(c) <= 32 for c in value) or "\\" in value:
        raise WorkerError("invalid_origin")
    try:
        url = urlsplit(value)
        allowed_fixture = allow_fixture and url.scheme == "http" and url.hostname == "127.0.0.1" and url.port is not None
        if (url.scheme != "https" and not allowed_fixture) or not url.hostname or url.username is not None or url.password is not None:
            raise WorkerError("invalid_origin")
        if url.path not in ("", "/") or url.query or url.fragment or "?" in value or "#" in value:
            raise WorkerError("invalid_origin")
        if url.port is not None and not 1 <= url.port <= 65535:
            raise WorkerError("invalid_origin")
    except ValueError as exc:
        raise WorkerError("invalid_origin") from exc
    return value.rstrip("/")


@dataclass(frozen=True)
class WorkerConfig:
    backend_origin: str
    company_id: str
    worker_id: str
    token_file: Path
    ledger_file: Path
    lock_file: Path = SHARED_LOCK

    @classmethod
    def load(cls, path):
        value = decode(read_private(path, 8192))
        expected = {"backend_origin", "company_id", "worker_id", "token_file", "ledger_file", "lock_file"}
        if set(value) != expected:
            raise WorkerError("invalid_configuration")
        try:
            company = str(uuid.UUID(value["company_id"]))
        except (ValueError, TypeError, AttributeError) as exc:
            raise WorkerError("invalid_company") from exc
        if not isinstance(value["worker_id"], str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", value["worker_id"]):
            raise WorkerError("invalid_worker")
        paths = [Path(value[name]) for name in ("token_file", "ledger_file", "lock_file") if isinstance(value[name], str)]
        if len(paths) != 3 or any(not p.is_absolute() for p in paths) or paths[2] != SHARED_LOCK:
            raise WorkerError("invalid_paths")
        if len(set(paths)) != 3 or Path(path) in paths:
            raise WorkerError("overlapping_paths")
        return cls(origin(value["backend_origin"]), company, value["worker_id"], *paths)


def load_token(path):
    private_parent(path)
    try:
        token = read_private(path, 512).decode("ascii").strip()
    except UnicodeError as exc:
        raise WorkerError("invalid_token_reference") from exc
    if not re.fullmatch(r"[A-Za-z0-9._~+/=-]{32,512}", token):
        raise WorkerError("invalid_token_reference")
    return token


@contextmanager
def model_lock(path):
    # Identical flock/open protocol to GunnAireLocalQA/local_qa.py:locked.
    # Require the pre-existing private parent instead of changing permissions.
    private_parent(path)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        regular(fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


class JSONClient:
    """Direct connections: no environment proxy and no redirect handling."""
    def __init__(self, base, *, token=None, allow_fixture=False, clock=time.monotonic, isolate=True):
        self.base = origin(base, allow_fixture=allow_fixture)
        self.token, self.clock = token, clock
        self.isolate, self.allow_fixture = isolate, allow_fixture

    def request(self, path, payload=None, *, timeout=10, deadline=None):
        if not path.startswith("/") or "?" in path or "#" in path:
            raise WorkerError("invalid_route")
        started = self.clock()
        end = min(started + timeout, deadline) if deadline is not None else started + timeout
        if end <= started:
            raise WorkerError("expired")
        data = None if payload is None else json.dumps(payload, allow_nan=False, separators=(",", ":")).encode()
        if data is not None and len(data) > BODY_LIMIT:
            raise WorkerError("body_too_large")
        if self.isolate:
            return isolated_request(self.base, self.token, self.allow_fixture, path, payload, end)
        url = urlsplit(self.base)
        cls = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
        conn = cls(url.hostname, url.port, timeout=end - started)
        try:
            headers = {"Accept": "application/json", "Content-Type": "application/json", "Accept-Encoding": "identity"}
            if self.token is not None:
                headers["Authorization"] = "Bearer " + self.token
            conn.connect()
            transport_socket = conn.sock
            if transport_socket is None:
                raise WorkerError("transport_unavailable")
            def remaining_time():
                remaining = end - self.clock()
                if remaining <= 0:
                    raise WorkerError("expired")
                transport_socket.settimeout(remaining)
            remaining_time()
            conn.request("GET" if data is None else "POST", path, body=data, headers=headers)
            remaining_time()
            response = conn.getresponse()
            if response.status != 200 or response.getheader("Content-Encoding", "identity") != "identity":
                raise WorkerError("http_unavailable")
            length = response.getheader("Content-Length")
            if length is not None and (not length.isdecimal() or int(length) > BODY_LIMIT):
                raise WorkerError("body_too_large")
            result = bytearray()
            while True:
                # Keep the original socket even when getresponse() transfers
                # a Connection: close socket away from conn.sock.
                remaining_time()
                part = response.read1(min(16_384, BODY_LIMIT + 1 - len(result)))
                if not part:
                    break
                result.extend(part)
                if len(result) > BODY_LIMIT:
                    raise WorkerError("body_too_large")
                if response.isclosed():
                    break
            if self.clock() > end:
                raise WorkerError("expired")
            if length is not None and len(result) != int(length):
                raise WorkerError("incomplete_body")
            return decode(result)
        except (OSError, http.client.HTTPException, ValueError) as exc:
            raise WorkerError("transport_unavailable") from exc
        finally:
            conn.close()


def request_child(pipe, base, token, allow_fixture, path, payload, deadline):
    """Spawn arguments travel over multiprocessing's private pipe, not argv."""
    try:
        result = JSONClient(base, token=token, allow_fixture=allow_fixture, isolate=False).request(
            path, payload, timeout=90, deadline=deadline)
        body = json.dumps({"ok": True, "value": result}, allow_nan=False, ensure_ascii=False, separators=(",", ":")).encode()
        if len(body) > BODY_LIMIT + 128:
            raise WorkerError("body_too_large")
        pipe.send_bytes(body)
    except (WorkerError, OSError, ValueError):
        pipe.send_bytes(b'{"ok":false}')
    finally:
        pipe.close()


def isolated_request(base, token, allow_fixture, path, payload, deadline, *, target=request_child):
    """A hung OS resolver cannot extend the parent job's monotonic deadline."""
    context = multiprocessing.get_context("spawn")
    parent, child = context.Pipe(duplex=False)
    process = context.Process(target=target, args=(child, base, token, allow_fixture, path, payload, deadline), daemon=True)
    try:
        process.start()
        child.close()
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not parent.poll(remaining):
            raise WorkerError("expired")
        value = decode(parent.recv_bytes(BODY_LIMIT + 128))
        if time.monotonic() >= deadline:
            raise WorkerError("expired")
        if value.get("ok") is not True or not isinstance(value.get("value"), dict):
            raise WorkerError("transport_unavailable")
        return value["value"]
    except (EOFError, OSError) as exc:
        raise WorkerError("transport_unavailable") from exc
    finally:
        parent.close(); child.close()
        if process.pid is not None:
            process.join(timeout=0.1)
            if process.is_alive():
                process.terminate(); process.join(timeout=1)
            if process.is_alive():
                process.kill(); process.join(timeout=1)
            process.close()


class PinnedOllama:
    def __init__(self, client=None, *, clock=time.monotonic):
        self.client = client or JSONClient(OLLAMA, allow_fixture=True, clock=clock)
        self.clock, self.deadline = clock, None

    def tags(self):
        data = self.client.request("/api/tags", timeout=5, deadline=self.deadline)
        values = data.get("models")
        matches = [m for m in values if isinstance(m, dict) and m.get("name") == MODEL] if isinstance(values, list) else []
        if len(matches) != 1 or matches[0].get("digest") != DIGEST or matches[0].get("remote_host") or matches[0].get("remote_model"):
            raise WorkerError("pinned_model_unavailable")
        return [MODEL]

    def ready(self):
        self.tags()
        data = self.client.request("/api/ps", timeout=5, deadline=self.deadline)
        models = data.get("models")
        if not isinstance(models, list) or any(not isinstance(m, dict) or m.get("name") != MODEL or m.get("digest") != DIGEST or m.get("remote_host") or m.get("remote_model") for m in models):
            raise WorkerError("competing_model")

    def chat(self, *, model, system_prompt, user_prompt, generation):
        if model != MODEL:
            raise WorkerError("unpinned_model")
        self.ready()
        started = self.clock()
        value = self.client.request("/api/chat", {"model": MODEL, "stream": False, "format": "json", "keep_alive": "2m",
            "messages": [{"role": "system", "content": system_prompt}, {"role": "user", "content": user_prompt}],
            "options": {"temperature": 0, "seed": 42, "num_ctx": 16384, "num_predict": 2048}},
            timeout=85, deadline=self.deadline)
        message = value.get("message")
        if value.get("model") != MODEL or value.get("done") is not True or value.get("done_reason") == "length" or not isinstance(message, dict) or message.get("tool_calls"):
            raise WorkerError("invalid_model_response")
        content = message.get("content")
        if not isinstance(content, str):
            raise WorkerError("invalid_model_response")
        return decode(content), {"model": MODEL, "elapsed_seconds": round(self.clock() - started, 3)}


def gateway(model):
    roles = {name: ModelRole(name, MODEL, True, "Pinned advisory task") for name in ("coder", "triage", "reviewer", "challenger")}
    policy = load_policy(Path(__file__).resolve().parent / "config/policy.json")
    return LocalAIGateway(Settings(timeout=85, cache_ttl=0, cache_entries=0, status_ttl=0),
        Config(OLLAMA, "0.13.3", roles, {}), policy, {}, client=model)


def resources(lock_path):
    check = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
        capture_output=True, text=True, timeout=5, check=True)
    if check.stdout.strip() != "1" or shutil.disk_usage(lock_path.parent).free < 2 * 1024**3:
        raise WorkerError("resource_unavailable")


def remember_claim(config, job_id):
    """Persist only an opaque hash, before inference. Never retain request text."""
    private_parent(config.ledger_file)
    fd = os.open(config.ledger_file, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        regular(fd)
        data = os.read(fd, MAX_JOBS * 65 + 1)
        if len(data) > MAX_JOBS * 65 or os.read(fd, 1):
            raise WorkerError("ledger_full")
        rows = data.splitlines()
        if any(not re.fullmatch(rb"[0-9a-f]{64}", row) for row in rows) or (data and not data.endswith(b"\n")):
            raise WorkerError("invalid_ledger")
        key = hashlib.sha256((config.company_id + "/" + config.worker_id + "/" + job_id).encode()).hexdigest().encode()
        if key in rows:
            raise WorkerError("already_attempted")
        if len(rows) >= MAX_JOBS:
            raise WorkerError("ledger_full")
        os.lseek(fd, 0, os.SEEK_END)
        if os.write(fd, key + b"\n") != 65:
            raise WorkerError("ledger_write_failed")
        os.fsync(fd)
    finally:
        os.close(fd)


class Worker:
    def __init__(self, config, backend, model, *, clock=time.monotonic, check_resources=resources):
        self.config, self.backend, self.model, self.clock = config, backend, model, clock
        self.check_resources = check_resources
        self.engine = gateway(model)

    def post(self, operation, fields, *, deadline=None):
        if operation not in PATHS:
            raise WorkerError("invalid_route")
        return self.backend.request("/api/local-ai/worker/" + operation,
            {"companyID": self.config.company_id, "workerID": self.config.worker_id, **fields}, timeout=10, deadline=deadline)

    def once(self):
        with model_lock(self.config.lock_file):
            self.check_resources(self.config.lock_file)
            self.model.deadline = None
            self.model.ready()
            heartbeat = self.post("heartbeat", {"ready": True, "busy": False, "model": MODEL, "modelDigest": DIGEST,
                "provider": "ollama", "local": True, "hostedFallbackEnabled": False})
            if heartbeat.get("accepted") is not True:
                raise WorkerError("heartbeat_rejected")
            started = self.clock()
            response = self.post("claim", {})
            job = response.get("job")
            if job is None and set(response) == {"job"}:
                return "idle"
            if not isinstance(job, dict):
                raise WorkerError("invalid_claim")
            required = {"companyID", "workerID", "jobID", "claimID", "task", "actorRole", "model", "modelDigest", "expiresInSeconds", "request"}
            if not required.issubset(job) or set(job) != required:
                raise WorkerError("invalid_claim")
            if job["companyID"] != self.config.company_id or job["workerID"] != self.config.worker_id or job["model"] != MODEL or job["modelDigest"] != DIGEST:
                raise WorkerError("claim_binding_mismatch")
            if any(not isinstance(job[k], str) or not re.fullmatch(r"[A-Za-z0-9_-]{16,128}", job[k]) for k in ("jobID", "claimID")):
                raise WorkerError("invalid_claim")
            lifetime = job["expiresInSeconds"]
            if type(lifetime) not in (int, float) or not math.isfinite(lifetime) or not 0 < lifetime <= 90:
                raise WorkerError("invalid_expiry")
            deadline = started + lifetime
            request = job["request"]
            if not isinstance(request, dict) or request.get("task") != job["task"] or not isinstance(job["actorRole"], str):
                raise WorkerError("invalid_claim")
            if self.clock() >= deadline - 1:
                return "expired"
            remember_claim(self.config, job["jobID"])
            binding = {key: job[key] for key in ("jobID", "claimID", "task")}
            self.model.deadline = deadline - 1
            try:
                self.check_resources(self.config.lock_file)
                result = self.engine.assist(request, job["actorRole"])
                completion = {**binding, "response": result}
            except (GatewayError, WorkerError, OSError, ValueError, subprocess.SubprocessError):
                completion = {**binding, "failureCode": "request_failed"}
            finally:
                self.model.deadline = None
            if self.clock() >= deadline:
                return "expired"
            try:
                accepted = self.post("complete", completion, deadline=deadline)
            except (WorkerError, OSError):
                return "completion_uncertain"
            if accepted.get("accepted") is not True:
                return "completion_uncertain"
            return "failed" if "failureCode" in completion else "completed"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True, help="Private JSON configuration path, never a token value")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--once", action="store_true")
    mode.add_argument("--loop", type=int, metavar="ITERATIONS", help="Explicit bounded loop, 1..1000 iterations")
    args = parser.parse_args(argv)
    if args.loop is not None and not 1 <= args.loop <= 1000:
        parser.error("loop must be between 1 and 1000")
    try:
        config = WorkerConfig.load(args.config)
        worker = Worker(config, JSONClient(config.backend_origin, token=load_token(config.token_file)), PinnedOllama())
        for index in range(args.loop or 1):
            status = worker.once()
            print(json.dumps({"status": status}), flush=True)
            if status in {"completion_uncertain", "expired", "failed"}:
                return 2
            if index + 1 < (args.loop or 1):
                time.sleep(5)
        return 0
    except KeyboardInterrupt:
        print(json.dumps({"status": "interrupted"}), flush=True)
        return 130
    except (WorkerError, OSError, ValueError, subprocess.SubprocessError):
        print(json.dumps({"status": "unavailable"}), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
