from __future__ import annotations

import hmac
import json
import socket
import time
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import gunnaire_local_ai_backend as routes
from Backend.test_local_ai_backend_routes import FakeGateway


class FakeRelay(FakeGateway):
    def __init__(self, company_id, secret):
        super().__init__()
        self.settings = SimpleNamespace(company_id=company_id, worker_secret=secret.encode("ascii"))
        self.secret = secret
        self.worker_calls = []
        self.before_result = lambda: None
        self.scope = None

    def authenticate_worker(self, header):
        return hmac.compare_digest(header, "Bearer " + self.secret)

    def heartbeat(self, body):
        self.worker_calls.append(body)
        return {"accepted": True}

    claim = heartbeat
    complete = heartbeat

    def assist(self, payload, *, actor_role, authorize, scope_id, deadline):
        self.scope = scope_id
        if authorize() is not True:
            raise routes.Forbidden("business_access_changed", "Access changed")
        self.before_result()
        return super().assist(payload, actor_role=actor_role)


class LocalAIRelayRouteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.patch = mock.patch.multiple(backend, DATA_ROOT=root, DB_PATH=root / "test.sqlite3",
            STORAGE_ROOT=root / "storage", AUTH_MODE="google-id-token",
            API_TOKEN="synthetic-business-api-token", PRIMARY_ADMIN_EMAIL="owner@example.invalid")
        self.patch.start()
        backend.initialize_database()
        self.session_id = str(uuid.uuid4())
        self.session_token = "synthetic-session-" + "s" * 48
        self.worker_token = "synthetic-worker-" + "w" * 48
        now = datetime.now(timezone.utc)
        with backend.db() as connection:
            connection.execute("INSERT OR REPLACE INTO users(email,role,is_active,created_at,updated_at) VALUES (?,?,?,?,?)",
                ("owner@example.invalid", "Admin", 1, now.isoformat(), now.isoformat()))
            connection.execute("INSERT INTO auth_sessions(id,token_hash,email,provider,provider_subject,created_at,expires_at,last_used_at) VALUES (?,?,?,?,?,?,?,?)",
                (self.session_id, backend.app_session_token_hash(self.session_token), "owner@example.invalid", "google", "synthetic-subject", now.isoformat(), (now + timedelta(hours=1)).isoformat(), now.isoformat()))
        self.relay = FakeRelay(routes.company_identity(), self.worker_token)
        self.gateway_patch = mock.patch.object(routes, "get_gateway", return_value=self.relay)
        self.gateway_patch.start()
        self.kind_patch = mock.patch.object(routes, "is_relay", side_effect=lambda value: isinstance(value, FakeRelay))
        self.kind_patch.start()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), routes.GunnAireLocalAIBackendHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.body = {"task": "operations_narrative", "input": "Synthetic dispatch facts only"}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.kind_patch.stop()
        self.gateway_patch.stop()
        self.patch.stop()
        self.temp.cleanup()

    def request(self, path, body=None, *, token=None, method="POST", content_type="application/json"):
        headers = {"Content-Type": content_type}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        data = None if body is None else body if isinstance(body, bytes) else json.dumps(body).encode()
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def change(self, statement, values=()):
        with backend.db() as connection:
            connection.execute(statement, values)

    def test_valid_application_session_reaches_relay_with_internal_scope(self):
        status, body = self.request(routes.ASSIST_PATH, self.body, token=self.session_token)
        self.assertEqual(status, 200)
        self.assertEqual(self.relay.scope, self.session_id)
        self.assertEqual(self.relay.calls, [(self.body, "Admin")])
        self.assertNotIn(self.session_id, json.dumps(body))

    def test_worker_credential_cannot_call_business_assist(self):
        status, _ = self.request(routes.ASSIST_PATH, self.body, token=self.worker_token)
        self.assertEqual(status, 401)
        self.assertEqual(self.relay.calls, [])

    def test_business_session_cannot_call_worker_routes(self):
        for path in routes.WORKER_PATHS:
            with self.subTest(path=path):
                status, _ = self.request(path, {}, token=self.session_token)
                self.assertEqual(status, 401)
        self.assertEqual(self.relay.worker_calls, [])

    def test_worker_routes_accept_only_the_separate_credential(self):
        for path in routes.WORKER_PATHS:
            with self.subTest(path=path):
                status, body = self.request(path, {}, token=self.worker_token)
                self.assertEqual(status, 200)
                self.assertTrue(body["accepted"])
        self.assertEqual(len(self.relay.worker_calls), 3)

    def test_development_api_token_is_not_an_outbound_business_session(self):
        with mock.patch.object(backend, "AUTH_MODE", "api-token"):
            status, body = self.request(routes.ASSIST_PATH, self.body, token=backend.API_TOKEN)
        self.assertEqual(status, 403)
        self.assertEqual(body["code"], "business_session_required")
        self.assertEqual(self.relay.calls, [])

    def test_worker_routes_are_absent_for_default_loopback_transport(self):
        self.gateway_patch.stop()
        self.gateway_patch = mock.patch.object(routes, "get_gateway", return_value=FakeGateway())
        self.gateway_patch.start()
        status, _ = self.request(next(iter(routes.WORKER_PATHS)), {}, token=self.worker_token)
        self.assertEqual(status, 404)

    def test_configured_company_must_match_the_authoritative_database(self):
        self.relay.settings.company_id = str(uuid.uuid4())
        status, _ = self.request(routes.ASSIST_PATH, self.body, token=self.session_token)
        self.assertEqual(status, 503)
        status, _ = self.request(next(iter(routes.WORKER_PATHS)), {}, token=self.worker_token)
        self.assertEqual(status, 503)
        self.assertEqual(self.relay.calls, [])
        self.assertEqual(self.relay.worker_calls, [])

    def test_revoked_session_blocks_result_even_if_gateway_returns_it(self):
        self.relay.before_result = lambda: self.change("UPDATE auth_sessions SET revoked_at=? WHERE id=?",
            (datetime.now(timezone.utc).isoformat(), self.session_id))
        status, body = self.request(routes.ASSIST_PATH, self.body, token=self.session_token)
        self.assertEqual(status, 403)
        self.assertEqual(body["code"], "business_access_changed")
        with backend.db() as connection:
            count = connection.execute("SELECT count(*) FROM audit_events WHERE action='generate-draft'").fetchone()[0]
        self.assertEqual(count, 0)

    def test_changed_role_blocks_result(self):
        self.relay.before_result = lambda: self.change("UPDATE users SET role='Field Technician' WHERE email=?", ("owner@example.invalid",))
        self.assertEqual(self.request(routes.ASSIST_PATH, self.body, token=self.session_token)[0], 403)

    def test_disabled_user_blocks_result(self):
        self.relay.before_result = lambda: self.change("UPDATE users SET is_active=0 WHERE email=?", ("owner@example.invalid",))
        self.assertEqual(self.request(routes.ASSIST_PATH, self.body, token=self.session_token)[0], 403)

    def test_expired_session_blocks_result(self):
        self.relay.before_result = lambda: self.change("UPDATE auth_sessions SET expires_at=? WHERE id=?",
            ((datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat(), self.session_id))
        self.assertEqual(self.request(routes.ASSIST_PATH, self.body, token=self.session_token)[0], 403)

    def test_company_change_blocks_result(self):
        self.relay.before_result = lambda: self.change("UPDATE company_identity SET company_id=?", (str(uuid.uuid4()),))
        self.assertEqual(self.request(routes.ASSIST_PATH, self.body, token=self.session_token)[0], 403)

    def test_revocation_during_audit_blocks_final_release(self):
        def audit(*args):
            self.change("UPDATE auth_sessions SET revoked_at=? WHERE id=?",
                (datetime.now(timezone.utc).isoformat(), self.session_id))
        with mock.patch.object(backend, "record_audit_event", side_effect=audit):
            status, body = self.request(routes.ASSIST_PATH, self.body, token=self.session_token)
        self.assertEqual(status, 403)
        self.assertNotIn("result", body)

    def test_admission_deadline_is_checked_after_audit(self):
        clock = [100.0]
        with mock.patch.object(routes.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(backend, "record_audit_event", side_effect=lambda *args: clock.__setitem__(0, 191.0)):
            status, body = self.request(routes.ASSIST_PATH, self.body, token=self.session_token)
        self.assertEqual(status, 503)
        self.assertEqual(body["code"], "local_ai_expired")

    def test_colliding_application_session_cannot_be_a_worker_credential(self):
        self.relay.secret = self.session_token
        self.relay.settings.worker_secret = self.session_token.encode("ascii")
        for path in (routes.ASSIST_PATH, next(iter(routes.WORKER_PATHS))):
            with self.subTest(path=path):
                status, body = self.request(path, self.body, token=self.session_token)
                self.assertEqual(status, 503)
                self.assertEqual(body["code"], "local_ai_credential_collision")
        self.assertEqual(self.relay.worker_calls, [])

    def test_colliding_business_api_token_cannot_be_a_worker_credential(self):
        with mock.patch.object(backend, "API_TOKEN", self.worker_token):
            status, body = self.request(next(iter(routes.WORKER_PATHS)), {}, token=self.worker_token)
        self.assertEqual(status, 503)
        self.assertEqual(body["code"], "local_ai_credential_collision")
        self.assertEqual(self.relay.worker_calls, [])

    def test_request_json_rejects_duplicate_keys_and_nonfinite_values(self):
        for body in [b'{"task":"a","task":"b"}', b'{"input":NaN}', b'{"input":Infinity}', b'{"input":1e999}', b'[]']:
            with self.subTest(body=body):
                status, _ = self.request(routes.ASSIST_PATH, body, token=self.session_token)
                self.assertEqual(status, 400)
                status, _ = self.request(next(iter(routes.WORKER_PATHS)), body, token=self.worker_token)
                self.assertEqual(status, 400)
        self.assertEqual(self.relay.calls, [])
        self.assertEqual(self.relay.worker_calls, [])

    def test_worker_body_bounds_and_media_type_are_enforced(self):
        path = next(iter(routes.WORKER_PATHS))
        self.assertEqual(self.request(path, {}, token=self.worker_token, content_type="text/plain")[0], 415)
        self.assertEqual(self.request(path, b' ' * 65537, token=self.worker_token)[0], 400)
        self.assertEqual(self.relay.worker_calls, [])


class LocalAIHTTPBoundTests(unittest.TestCase):
    def test_capacity_rejects_excess_connections_and_releases_after_timeout(self):
        server = routes.BoundedBusinessServer(("127.0.0.1", 0), routes.GunnAireLocalAIBackendHandler,
                                               max_active_requests=1, socket_timeout=0.2)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        first = socket.create_connection(server.server_address, timeout=2)
        second = None
        try:
            first.sendall(b"GET /health HTTP/1.1\r\n")
            # The first request has no terminating headers and occupies the sole slot.
            deadline = time.monotonic() + 1
            while server._request_slots.acquire(blocking=False):
                server._request_slots.release()
                if time.monotonic() >= deadline:
                    self.fail("First connection was not admitted")
                time.sleep(0.005)
            second = socket.create_connection(server.server_address, timeout=2)
            second.settimeout(1)
            self.assertEqual(second.recv(1), b"")
            first.settimeout(1)
            self.assertEqual(first.recv(1), b"")
            # A completed timeout returns the slot, allowing normal health traffic.
            deadline = time.monotonic() + 1
            while not server._request_slots.acquire(blocking=False):
                if time.monotonic() >= deadline:
                    self.fail("Socket timeout did not release request capacity")
                time.sleep(0.005)
            server._request_slots.release()
            with urllib.request.urlopen(f"http://127.0.0.1:{server.server_port}/health", timeout=2) as response:
                self.assertEqual(response.status, 200)
        finally:
            first.close()
            if second is not None:
                second.close()
            server.shutdown(); server.server_close(); thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
