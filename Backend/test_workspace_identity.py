from __future__ import annotations

import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from Backend import gunnaire_backend as backend


class WorkspaceIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.configuration = mock.patch.multiple(
            backend,
            DATA_ROOT=root,
            DB_PATH=root / "backend.sqlite3",
            STORAGE_ROOT=root / "storage",
            AUTH_MODE="google-id-token",
            PRIMARY_ADMIN_EMAIL="owner@gunnaire.com",
        )
        self.configuration.start()
        backend.initialize_database()
        self.tokens = {}
        with backend.db() as connection:
            for role in ("Admin", "Dispatcher", "Field Technician", "Accounting", "Standard"):
                email = role.lower().replace(" ", ".") + "@gunnaire.com"
                connection.execute(
                    "INSERT INTO users(email, role, is_active, created_at, updated_at) VALUES (?, ?, 1, ?, ?)",
                    (email, role, backend.utc_now(), backend.utc_now()),
                )
        for role in ("Admin", "Dispatcher", "Field Technician", "Accounting", "Standard"):
            email = role.lower().replace(" ", ".") + "@gunnaire.com"
            self.tokens[role] = backend.create_app_session(email, "google", "test-" + role)[0]
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.configuration.stop()
        self.directory.cleanup()

    def request(self, *, token=None, payload=None, method="GET", path="/api/workspace"):
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        request = urllib.request.Request(
            self.base_url + path,
            method=method,
            headers=headers,
            data=json.dumps(payload).encode() if payload is not None else None,
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def workspace(self, role="Admin"):
        status, body = self.request(token=self.tokens[role])
        self.assertEqual(status, 200)
        return body["workspace"]

    def binding_payload(self, **changes):
        return {
            "expectedCompanyID": self.workspace()["companyID"],
            "containerID": "iCloud.com.gunnaire.businesssuite",
            "environment": "development",
            "cloudAccountHash": "a" * 64,
            "confirmCompanyDataOwnership": True,
            **changes,
        }

    def bind(self, payload, role="Admin"):
        return self.request(token=self.tokens[role], payload=payload, method="POST", path="/api/workspace/bind")

    def test_identity_is_server_owned_durable_and_shared_by_approved_roles(self):
        before = self.workspace()
        self.assertEqual(str(uuid.UUID(before["companyID"])), before["companyID"])
        self.assertEqual(before["bindings"], [])
        backend.initialize_database()
        self.assertEqual(self.workspace(), before)
        for role in self.tokens:
            self.assertEqual(self.workspace(role), before)
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(backend, "DB_PATH", Path(directory) / "other.sqlite3"):
                backend.initialize_database()
                self.assertNotEqual(backend.company_workspace_identity()["companyID"], before["companyID"])

    def test_reads_and_writes_require_current_business_sessions(self):
        payload = self.binding_payload()
        self.assertEqual(self.request()[0], 401)
        with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="legacy-test-token"):
            self.assertEqual(self.request(token="legacy-test-token")[0], 403)
            self.assertEqual(self.request(token="legacy-test-token", payload=payload, method="POST", path="/api/workspace/bind")[0], 403)
        for role in self.tokens:
            if role != "Admin":
                self.assertEqual(self.bind(payload, role)[0], 403)
        self.assertEqual(self.workspace()["bindings"], [])

    def test_approval_is_immutable_idempotent_and_environment_scoped(self):
        payload = self.binding_payload()
        status, first = self.bind(payload)
        self.assertEqual(status, 201)
        binding = first["binding"]
        self.assertEqual(str(uuid.UUID(binding["replicaID"])), binding["replicaID"])
        self.assertEqual(binding["cloudAccountHash"], payload["cloudAccountHash"])
        self.assertEqual(binding["companyID"], payload["expectedCompanyID"])
        status, replay = self.bind(payload)
        self.assertEqual(status, 200)
        self.assertEqual(replay, first)
        self.assertEqual(self.bind({**payload, "cloudAccountHash": "b" * 64})[0], 409)
        status, production = self.bind({**payload, "environment": "production", "cloudAccountHash": "c" * 64})
        self.assertEqual(status, 201)
        self.assertNotEqual(production["binding"]["replicaID"], binding["replicaID"])
        with backend.db() as connection:
            audits = connection.execute("SELECT * FROM audit_events WHERE subject_type = 'cloudkit-workspace'").fetchall()
        self.assertEqual(len(audits), 2)
        self.assertEqual({row["subject_id"] for row in audits}, {binding["replicaID"], production["binding"]["replicaID"]})

    def test_binding_rejects_stale_company_invalid_metadata_and_unconfirmed_ownership(self):
        payload = self.binding_payload()
        self.assertEqual(self.bind({**payload, "expectedCompanyID": str(uuid.uuid4())})[0], 409)
        for changes in (
            {"expectedCompanyID": ""}, {"expectedCompanyID": True},
            {"containerID": "iCloud.another.company"}, {"environment": "Production"},
            {"cloudAccountHash": ""}, {"cloudAccountHash": "x" * 64},
            {"cloudAccountHash": "a" * 65}, {"cloudAccountHash": ["a" * 64]},
            {"confirmCompanyDataOwnership": False}, {"confirmCompanyDataOwnership": 1},
        ):
            with self.subTest(changes=changes):
                self.assertEqual(self.bind({**payload, **changes})[0], 400)
        self.assertEqual(self.bind([])[0], 400)
        self.assertEqual(self.workspace()["bindings"], [])

    def test_binding_requires_recent_authentication_and_rejects_revoked_or_demoted_admin(self):
        payload = self.binding_payload()
        token_hash = backend.app_session_token_hash(self.tokens["Admin"])
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at = ? WHERE token_hash = ?", ((datetime.now(timezone.utc) - timedelta(minutes=11)).isoformat(), token_hash))
        self.assertEqual(self.bind(payload)[0], 403)
        self.assertEqual(self.workspace()["bindings"], [])
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at = ? WHERE token_hash = ?", (backend.utc_now(), token_hash))
            connection.execute("UPDATE users SET role = 'Standard' WHERE email = 'admin@gunnaire.com'")
        self.assertEqual(self.bind(payload)[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET revoked_at = ? WHERE token_hash = ?", (backend.utc_now(), token_hash))
        self.assertEqual(self.request(token=self.tokens["Admin"])[0], 401)

    def test_concurrent_conflicting_approvals_have_one_winner_and_one_audit(self):
        payload = self.binding_payload()
        barrier = threading.Barrier(2)
        def approve(account_hash):
            barrier.wait(timeout=5)
            return self.bind({**payload, "cloudAccountHash": account_hash})
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(approve, ["a" * 64, "b" * 64]))
        self.assertEqual(sorted(result[0] for result in results), [201, 409])
        self.assertEqual(len(self.workspace()["bindings"]), 1)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM audit_events WHERE subject_type = 'cloudkit-workspace'").fetchone()[0], 1)

    def test_audit_failure_rolls_back_approval_and_allows_safe_retry(self):
        payload = self.binding_payload()
        with mock.patch.object(backend, "record_audit_event", side_effect=sqlite3.OperationalError("test audit unavailable")):
            self.assertEqual(self.bind(payload)[0], 503)
        self.assertEqual(self.workspace()["bindings"], [])
        self.assertEqual(self.bind(payload)[0], 201)

    def test_missing_company_identity_never_reassigns_an_approved_replica(self):
        payload = self.binding_payload()
        self.assertEqual(self.bind(payload)[0], 201)
        with backend.db() as connection:
            connection.execute("DELETE FROM company_identity")
        self.assertEqual(self.request(token=self.tokens["Admin"])[0], 503)
        with self.assertRaises(sqlite3.DatabaseError):
            backend.initialize_database()
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM company_identity").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT count(*) FROM cloudkit_workspace_bindings").fetchone()[0], 1)

    def test_admin_revoked_after_authorization_cannot_commit_a_binding(self):
        payload = self.binding_payload()
        original = backend.GunnAireBackendHandler.approve_cloudkit_workspace
        token_hash = backend.app_session_token_hash(self.tokens["Admin"])
        def revoke_then_approve(handler):
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at = ? WHERE token_hash = ?", (backend.utc_now(), token_hash))
            original(handler)
        with mock.patch.object(backend.GunnAireBackendHandler, "approve_cloudkit_workspace", revoke_then_approve):
            self.assertEqual(self.bind(payload)[0], 403)
        self.assertEqual(self.workspace("Field Technician")["bindings"], [])

    def test_current_apple_session_can_approve_and_concurrent_retries_keep_original_evidence(self):
        self.tokens["Admin"] = backend.create_app_session("admin@gunnaire.com", "apple", "apple-workspace-owner")[0]
        payload = self.binding_payload()
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(self.bind, [payload, payload]))
        self.assertEqual(sorted(result[0] for result in results), [200, 201])
        self.assertEqual(results[0][1], results[1][1])
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM audit_events WHERE subject_type = 'cloudkit-workspace'").fetchone()[0], 1)


if __name__ == "__main__":
    unittest.main()
