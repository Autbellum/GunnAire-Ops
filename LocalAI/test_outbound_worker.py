"""Synthetic only: injected HTTP/model clients, temporary files and flock."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import tempfile
import time
import threading
import unittest
from unittest.mock import patch
import uuid

from LocalAI import outbound_worker as w


def synthetic_hung_request(pipe, *args):
    time.sleep(10)


def synthetic_success_request(pipe, *args):
    pipe.send_bytes(b'{"ok":true,"value":{"fixture":true}}')
    pipe.close()


class FakeModel:
    def __init__(self, clock):
        self.deadline = None
        self.clock = clock
        self.calls = 0
        self.after = lambda: None
        self.available = True

    def ready(self):
        if not self.available:
            raise w.WorkerError("unavailable")

    def tags(self):
        self.ready()
        return [w.MODEL]

    def chat(self, **kwargs):
        self.calls += 1
        assert kwargs["model"] == w.MODEL
        self.after()
        return {"subject": "Fixture", "body": "Reviewed fixture only.", "warnings": []}, {"model": w.MODEL}


class FakeBackend:
    def __init__(self, job):
        self.job, self.requests = job, []
        self.claim_hook = lambda: None
        self.uncertain = False

    def request(self, path, payload, **kwargs):
        self.requests.append((path, payload, kwargs))
        if path.endswith("/claim"):
            self.claim_hook()
            return {"job": self.job}
        if path.endswith("/complete") and self.uncertain:
            raise w.WorkerError("transport_unavailable")
        return {"accepted": True}


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.clock = [100.0]
        self.config = w.WorkerConfig("https://fixture.example.invalid", str(uuid.uuid4()), "mac-fixture",
            self.root / "token", self.root / "attempts", self.root / ".lock")
        self.job = {"companyID": self.config.company_id, "workerID": self.config.worker_id,
            "jobID": "job_fixture_123456789", "claimID": "claim_fixture_123456789", "task": "customer_email_draft",
            "actorRole": "Admin", "model": w.MODEL, "modelDigest": w.DIGEST, "expiresInSeconds": 90,
            "request": {"task": "customer_email_draft", "input": "Synthetic service visit", "context": {}, "baseline": {}}}
        self.backend = FakeBackend(self.job)
        self.model = FakeModel(self.clock)
        self.worker = w.Worker(self.config, self.backend, self.model, clock=lambda: self.clock[0], check_resources=lambda _: None)

    def test_success_is_serial_and_gateway_cache_is_disabled(self):
        self.assertEqual(self.worker.once(), "completed")
        self.assertEqual(self.model.calls, 1)
        self.assertEqual([r[0].rsplit("/", 1)[1] for r in self.backend.requests], ["heartbeat", "claim", "complete"])
        result = self.backend.requests[-1][1]["response"]
        self.assertFalse(result["cached"])
        self.assertTrue(result["advisoryOnly"])
        self.assertEqual(result["model"], w.MODEL)
        self.assertEqual(len(self.worker.engine.cache), 0)
        self.assertEqual(len(self.config.ledger_file.read_bytes()), 65)
        self.assertNotIn(b"Synthetic", self.config.ledger_file.read_bytes())

    def test_uncertain_completion_never_regenerates_even_in_new_worker(self):
        self.backend.uncertain = True
        self.assertEqual(self.worker.once(), "completion_uncertain")
        second = w.Worker(self.config, self.backend, self.model, clock=lambda: self.clock[0], check_resources=lambda _: None)
        with self.assertRaisesRegex(w.WorkerError, "already_attempted"):
            second.once()
        self.assertEqual(self.model.calls, 1)
        self.assertEqual(sum(p.endswith("/complete") for p, _, _ in self.backend.requests), 1)

    def test_expiry_accounts_for_claim_network_time(self):
        self.job["expiresInSeconds"] = 3
        self.backend.claim_hook = lambda: self.clock.__setitem__(0, 104.0)
        self.assertEqual(self.worker.once(), "expired")
        self.assertEqual(self.model.calls, 0)
        self.assertFalse(self.config.ledger_file.exists())

    def test_expiry_after_inference_discards_completion(self):
        self.model.after = lambda: self.clock.__setitem__(0, 191.0)
        self.assertEqual(self.worker.once(), "expired")
        self.assertEqual(self.model.calls, 1)
        self.assertEqual(len(self.backend.requests), 2)
        with self.assertRaisesRegex(w.WorkerError, "already_attempted"):
            self.worker.once()

    def test_scope_model_digest_and_role_are_checked_before_model(self):
        for key, bad in [("companyID", str(uuid.uuid4())), ("workerID", "other"), ("model", "other"), ("modelDigest", "0" * 64)]:
            with self.subTest(key=key):
                old = self.job[key]; self.job[key] = bad
                with self.assertRaises(w.WorkerError):
                    self.worker.once()
                self.job[key] = old
        self.job["actorRole"] = "Unknown"
        self.assertEqual(self.worker.once(), "failed")
        self.assertEqual(self.model.calls, 0)
        self.assertEqual(self.backend.requests[-1][1]["failureCode"], "request_failed")

    def test_nonfinite_and_overlong_expiry_rejected(self):
        for value in (float("nan"), float("inf"), True, 91, -1):
            self.job["expiresInSeconds"] = value
            with self.assertRaises(w.WorkerError):
                self.worker.once()
        self.assertEqual(self.model.calls, 0)

    def test_gateway_rejects_secret_input_before_inference(self):
        self.job["request"]["input"] = "password=fixture-secret"
        self.assertEqual(self.worker.once(), "failed")
        self.assertEqual(self.model.calls, 0)
        self.assertNotIn("fixture-secret", json.dumps(self.backend.requests[-1][1]))

    def test_busy_shared_lock_prevents_heartbeat_claim_and_model(self):
        with w.model_lock(self.config.lock_file):
            with self.assertRaises(BlockingIOError):
                self.worker.once()
        self.assertEqual(self.backend.requests, [])
        self.assertEqual(self.model.calls, 0)

    def test_resource_failure_prevents_claim(self):
        self.worker.check_resources = lambda _: (_ for _ in ()).throw(w.WorkerError("pressure"))
        with self.assertRaises(w.WorkerError):
            self.worker.once()
        self.assertEqual(self.backend.requests, [])

    def test_idle_does_not_infer_or_create_ledger(self):
        self.backend.job = None
        self.assertEqual(self.worker.once(), "idle")
        self.assertEqual(self.model.calls, 0)
        self.assertFalse(self.config.ledger_file.exists())

    def test_protected_regular_token_only(self):
        self.config.token_file.write_text("x" * 40)
        self.config.token_file.chmod(0o600)
        self.assertEqual(w.load_token(self.config.token_file), "x" * 40)
        self.config.token_file.chmod(0o644)
        with self.assertRaises(w.WorkerError):
            w.load_token(self.config.token_file)
        fifo = self.root / "fifo"; os.mkfifo(fifo, 0o600)
        with self.assertRaises(w.WorkerError):
            w.load_token(fifo)
        link = self.root / "link"; link.symlink_to(self.config.token_file)
        with self.assertRaises(OSError):
            w.load_token(link)

    def test_ledger_limit_and_corruption_fail_closed(self):
        self.config.ledger_file.write_bytes(b"0" * 64 + b"\n")
        self.config.ledger_file.chmod(0o600)
        with patch.object(w, "MAX_JOBS", 1):
            with self.assertRaisesRegex(w.WorkerError, "ledger_full"):
                w.remember_claim(self.config, "new")
        self.config.ledger_file.write_bytes(b"broken")
        with self.assertRaises(w.WorkerError):
            w.remember_claim(self.config, "new")

    def test_origin_and_configuration_do_not_accept_insecure_or_embedded_secrets(self):
        for value in ("http://business.invalid", "https://user:secret@business.invalid", "https://business.invalid?q=x",
                      "https://business.invalid/#x", "https://business.invalid/api", "https://business.invalid?", "https://business.invalid\n"):
            with self.assertRaises(w.WorkerError):
                w.origin(value)
        self.assertEqual(w.origin("https://business.invalid/"), "https://business.invalid")
        self.assertEqual(w.origin("http://127.0.0.1:49152", allow_fixture=True), "http://127.0.0.1:49152")
        with self.assertRaises(w.WorkerError):
            w.origin("http://127.0.0.1:49152")
        value = {"backend_origin": self.config.backend_origin, "company_id": self.config.company_id,
            "worker_id": self.config.worker_id, "token_file": str(self.config.token_file),
            "ledger_file": str(self.config.ledger_file), "lock_file": str(w.SHARED_LOCK)}
        path = self.root / "config.json"; path.write_text(json.dumps(value)); path.chmod(0o600)
        self.assertEqual(w.WorkerConfig.load(path).lock_file, w.SHARED_LOCK)
        value["token"] = "never-inline"; path.write_text(json.dumps(value))
        with self.assertRaises(w.WorkerError):
            w.WorkerConfig.load(path)

    def test_nonfinite_or_duplicate_json_is_rejected(self):
        for body in (b'{"job":NaN}', b'{"job":1e999}', b'{"job":-1e999}', b'{"job":null,"job":{}}', b'[]'):
            with self.assertRaises(w.WorkerError):
                w.decode(body)


class PinnedTests(unittest.TestCase):
    def test_real_http_connection_close_complete_and_truncated_response(self):
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                body = b'{"fixture":true}'
                self.send_response(200)
                self.send_header("Connection", "close")
                if self.path != "/eof":
                    self.send_header("Content-Length", str(len(body) + (10 if self.path == "/short" else 0)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *args): pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            base = "http://127.0.0.1:" + str(server.server_port)
            for isolate in (False, True):
                client = w.JSONClient(base, allow_fixture=True, isolate=isolate)
                for path in ("/length", "/eof"):
                    self.assertEqual(client.request(path), {"fixture": True})
                with self.assertRaises(w.WorkerError): client.request("/short")
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=2)

    def test_request_process_deadline_terminates_synthetic_stall(self):
        started = time.monotonic()
        with self.assertRaisesRegex(w.WorkerError, "expired"):
            w.isolated_request("https://fixture.invalid", None, False, "/fixture", {}, started + 0.2,
                target=synthetic_hung_request)
        self.assertLess(time.monotonic() - started, 3)
        result = w.isolated_request("https://fixture.invalid", None, False, "/fixture", {}, time.monotonic() + 5,
            target=synthetic_success_request)
        self.assertEqual(result, {"fixture": True})

    def test_exact_digest_competing_models_and_tool_calls(self):
        class Client:
            digest = w.DIGEST
            loaded = []
            tools = False
            def request(self, path, payload=None, **kwargs):
                if path == "/api/tags": return {"models": [{"name": w.MODEL, "digest": self.digest}]}
                if path == "/api/ps": return {"models": self.loaded}
                self.payload = payload
                return {"model": w.MODEL, "done": True, "message": {"content": '{"summary":"fixture"}', "tool_calls": [{}] if self.tools else []}}
        client = Client(); model = w.PinnedOllama(client)
        model.ready()
        client.digest = "bad"
        with self.assertRaises(w.WorkerError): model.ready()
        client.digest = w.DIGEST; client.loaded = [{"name": "other", "digest": w.DIGEST}]
        with self.assertRaises(w.WorkerError): model.ready()
        client.loaded = []; client.tools = True
        with self.assertRaises(w.WorkerError): model.chat(model=w.MODEL, system_prompt="fixture", user_prompt="fixture", generation={})
        client.tools = False
        model.chat(model=w.MODEL, system_prompt="fixture", user_prompt="fixture", generation={"num_predict": 999999})
        self.assertEqual(client.payload["options"]["num_predict"], 2048)
        self.assertEqual(client.payload["model"], w.MODEL)

    def test_http_rejects_redirect_and_oversize_without_following_or_proxy(self):
        class Response:
            status = 302
            def getheader(self, name, default=None):
                return "999999" if name == "Content-Length" else default
        class Connection:
            calls = []
            def __init__(self, host, port, timeout): self.calls.append((host, port)); self.sock = self
            def connect(self): pass
            def settimeout(self, value): pass
            def request(self, *args, **kwargs): pass
            def getresponse(self): return Response()
            def close(self): pass
        with patch.object(w.http.client, "HTTPSConnection", Connection), patch.dict(os.environ, {"HTTPS_PROXY": "http://secret.invalid:8080"}):
            client = w.JSONClient("https://business.invalid", isolate=False)
            with self.assertRaises(w.WorkerError): client.request("/fixture")
            Response.status = 200
            with self.assertRaises(w.WorkerError): client.request("/fixture")
        self.assertEqual(Connection.calls, [("business.invalid", None), ("business.invalid", None)])

    def test_deadline_remains_bound_when_connection_transfers_socket_to_response(self):
        clock = [0.0]
        class Response:
            status = 200
            reads = 0
            def getheader(self, name, default=None): return default
            def isclosed(self): return False
            def read1(self, limit):
                self.reads += 1
                clock[0] = 11.0
                return b'{"fixture":true}'
        class Connection:
            timeouts = []
            def __init__(self, *args, **kwargs): self.sock = self
            def connect(self): pass
            def settimeout(self, value): self.timeouts.append(value)
            def request(self, *args, **kwargs): pass
            def getresponse(self): self.sock = None; return Response()
            def close(self): pass
        with patch.object(w.http.client, "HTTPSConnection", Connection):
            client = w.JSONClient("https://business.invalid", clock=lambda: clock[0], isolate=False)
            with self.assertRaisesRegex(w.WorkerError, "expired"):
                client.request("/fixture", timeout=10)
        self.assertEqual(Connection.timeouts, [10.0, 10.0, 10.0])


if __name__ == "__main__":
    unittest.main()
