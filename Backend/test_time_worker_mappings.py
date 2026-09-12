from __future__ import annotations

import copy
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet
from Backend import gunnaire_backend as backend
from Backend import time_worker_mappings as workers


class TimeWorkerMappingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.settings = mock.patch.multiple(backend, DATA_ROOT=root, DB_PATH=root / "time.sqlite3", STORAGE_ROOT=root / "files",
            AUTH_MODE="google-id-token", PRIMARY_ADMIN_EMAIL="owner@example.invalid", QBO_TOKEN_ENCRYPTION_KEY=Fernet.generate_key().decode())
        self.settings.start()
        backend.initialize_database()
        self.worker = "field.technician@example.invalid"
        self.tokens, self.sessions, self.reads = {}, {}, []
        self.before_read = lambda: None
        self.remote = {"Id": "55", "SyncToken": "0", "Active": True, "DisplayName": "Taylor Technician",
                       "SSN": "private-fixture-tax", "BillAddr": {"Line1": "Private home"}, "HourlyRate": 999}
        with backend.db() as connection:
            self.company = connection.execute("SELECT company_id FROM company_identity").fetchone()[0]
            connection.execute("INSERT INTO qbo_connections VALUES (1,'realm','cipher','sandbox','client','grant','updated')")
            for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
                account = role.lower().replace(" ", ".") + "@example.invalid"
                connection.execute("INSERT INTO users VALUES (?,?,1,?,?)", (account, role, backend.utc_now(), backend.utc_now()))
        for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
            account = role.lower().replace(" ", ".") + "@example.invalid"
            self.tokens[role] = backend.create_app_session(account, "google", "fixture")[0]
            with backend.db() as connection:
                self.sessions[role] = connection.execute("SELECT id FROM auth_sessions WHERE token_hash=?",
                    (backend.app_session_token_hash(self.tokens[role]),)).fetchone()[0]
        fixture = self
        class Provider:
            def __init__(self, context, authorize, bearer_loader=None):
                self.authorize = authorize
            def read(self, kind, identifier):
                fixture.reads.append((kind, identifier))
                fixture.before_read()
                self.authorize()
                return copy.deepcopy(fixture.remote)
        self.provider_patch = mock.patch.object(backend, "TimeWorkerQBOProvider", Provider)
        self.provider_patch.start()
        self.service = workers.TimeWorkerMappings(backend.db, Provider, backend.encrypt_catalog_payload,
            backend.decrypt_catalog_payload, backend.record_audit_event)
        self.admin = self.sessions["Admin"]

    def tearDown(self):
        self.provider_patch.stop()
        self.settings.stop()
        self.directory.cleanup()

    def context(self, *, role="Admin", candidate=False, **changes):
        payload = {"companyID": self.company, "workerEmail": self.worker}
        if candidate:
            payload.update(kind="Employee", providerID="55")
        return self.service.context(self.sessions[role], {**payload, **changes}, candidate=candidate)

    def payload(self, **changes):
        result = self.context(candidate=True)
        mapping = result["mapping"]
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox", "workerEmail": self.worker,
                "connectionRevision": result["connectionRevision"], "operationID": str(uuid.uuid4()),
                "expectedRevision": mapping["revision"] if mapping else 0, "kind": "Employee", "providerID": "55",
                "referenceRevision": result["candidate"]["referenceRevision"], "enabled": True, **changes}

    def save(self, payload=None):
        return self.service.save(self.admin, payload or self.payload())

    def expect(self, code, function):
        with self.assertRaises(workers.AttemptError) as error:
            function()
        self.assertEqual(error.exception.code, code)

    def change(self, sql, args=()):
        with backend.db() as connection:
            connection.execute(sql, args)

    def test_read_only_context_needs_no_device_oauth_or_provider_read(self):
        result = self.context(role="Accounting")
        self.assertIsNone(result["mapping"])
        self.assertIsNone(result["candidate"])
        self.assertEqual(result["protocolVersion"], 1)
        self.assertEqual(result["realmID"], "realm")
        self.assertFalse(self.reads)

    def test_admin_reviews_exact_worker_but_private_provider_fields_never_escape(self):
        result = self.context(candidate=True)
        self.assertEqual(result["candidate"]["displayName"], "Taylor Technician")
        self.assertEqual(set(result["candidate"]), {"kind", "providerID", "displayName", "referenceRevision"})
        for forbidden in ("SSN", "private-fixture", "Private home", "HourlyRate", "cipher", "grant_fingerprint"):
            self.assertNotIn(forbidden, json.dumps(result))

    def test_same_operation_saves_once_and_replays_without_provider_read(self):
        payload = self.payload()
        first = self.save(payload)
        self.reads.clear()
        second = self.save(payload)
        self.assertEqual(first["mapping"], second["mapping"])
        self.assertFalse(first["replayed"])
        self.assertTrue(second["replayed"])
        self.assertTrue(first["mapping"]["usable"])
        self.assertEqual(first["mapping"]["revision"], 1)
        self.assertFalse(self.reads)

    def test_vendor_mapping_is_distinct_from_employee_with_same_id(self):
        review = self.context(candidate=True, kind="Vendor")
        payload = self.payload(kind="Vendor", referenceRevision=review["candidate"]["referenceRevision"])
        self.assertEqual(self.save(payload)["mapping"]["kind"], "Vendor")

    def test_accounting_can_read_but_cannot_map_or_review_other_qbo_workers(self):
        payload = self.payload()
        self.expect("administrator_required", lambda: self.service.save(self.sessions["Accounting"], payload))
        self.expect("administrator_required", lambda: self.context(role="Accounting", candidate=True))
        self.save(payload)
        self.assertTrue(self.context(role="Accounting")["mapping"]["usable"])

    def test_field_dispatcher_and_standard_cannot_read_team_mapping(self):
        payload = self.payload()
        for role in ("Field Technician", "Dispatcher", "Standard"):
            self.expect("office_required", lambda: self.context(role=role))
            self.expect("administrator_required", lambda: self.service.save(self.sessions[role], payload))

    def test_actor_inactive_role_change_missing_and_revoked_fail_closed(self):
        payload = self.payload()
        self.expect("administrator_required", lambda: self.service.save("missing", payload))
        for statement in ("UPDATE users SET is_active=0 WHERE role='Admin'",
                          "UPDATE users SET role='Standard' WHERE role='Admin'",
                          "UPDATE auth_sessions SET revoked_at='now'"):
            self.change(statement)
            self.expect("administrator_required", lambda: self.save(payload))
            self.change("UPDATE users SET is_active=1,role='Admin' WHERE email='admin@example.invalid'")
            self.change("UPDATE auth_sessions SET revoked_at=NULL")

    def test_future_expired_and_naive_session_timestamps_cannot_authorize(self):
        payload = self.payload()
        with backend.db() as connection:
            old = dict(connection.execute("SELECT * FROM auth_sessions WHERE id=?", (self.admin,)).fetchone())
        for column, value in (("created_at", "2999-01-01T00:00:00+00:00"), ("expires_at", "2000-01-01T00:00:00+00:00"),
                              ("created_at", "2020-01-01T00:00:00"), ("expires_at", "invalid")):
            self.change("UPDATE auth_sessions SET created_at=?,expires_at=? WHERE id=?", (old["created_at"], old["expires_at"], self.admin))
            self.change("UPDATE auth_sessions SET " + column + "=? WHERE id=?", (value, self.admin))
            self.expect("administrator_required", lambda: self.save(payload))

    def test_primary_email_does_not_bypass_the_registered_role(self):
        payload = self.payload()
        self.change("UPDATE users SET role='Standard' WHERE email='admin@example.invalid'")
        with mock.patch.object(backend, "PRIMARY_ADMIN_EMAIL", "admin@example.invalid"):
            self.expect("administrator_required", lambda: self.save(payload))

    def test_company_realm_environment_and_epoch_are_exact(self):
        payload = self.payload()
        for field, value, code in (("companyID", str(uuid.uuid4()), "company_changed"), ("realmID", "other", "provider_changed"),
                                   ("environment", "production", "provider_changed"), ("connectionRevision", "0" * 64, "grant_changed")):
            self.expect(code, lambda: self.save({**payload, field: value}))

    def test_unknown_worker_rejected_but_inactive_worker_keeps_historical_identity(self):
        self.expect("worker_missing", lambda: self.context(workerEmail="unknown@example.invalid"))
        self.change("UPDATE users SET is_active=0 WHERE email=?", (self.worker,))
        self.assertTrue(self.save()["mapping"]["usable"])

    def test_reconnect_keeps_original_mapping_but_requires_admin_review(self):
        original = self.save()["mapping"]
        self.change("UPDATE qbo_connections SET authorized_at='replacement'")
        current = self.context()["mapping"]
        self.assertEqual(current["providerID"], original["providerID"])
        self.assertEqual(current["revision"], original["revision"])
        self.assertFalse(current["usable"])
        self.assertTrue(self.save()["mapping"]["usable"])

    def test_disabled_approver_invalidates_mapping_without_erasing_it(self):
        self.save()
        self.change("UPDATE users SET is_active=0 WHERE email='admin@example.invalid'")
        mapping = self.context(role="Accounting")["mapping"]
        self.assertFalse(mapping["usable"])
        self.assertEqual(mapping["providerID"], "55")

    def test_inactive_wrong_id_and_missing_identity_do_not_save(self):
        payload = self.payload()
        original = dict(self.remote)
        for changes in ({"Active": False}, {"Id": "other"}, {"DisplayName": ""}, {"SyncToken": None}):
            self.remote = {**original, **changes}
            with self.assertRaises(workers.AttemptError):
                self.save(payload)
            self.assertIsNone(self.context()["mapping"])

    def test_changed_name_or_sync_token_requires_a_new_visible_review(self):
        payload = self.payload()
        for field, value in (("DisplayName", "Different Worker"), ("SyncToken", "1")):
            self.remote[field] = value
            self.expect("worker_changed", lambda: self.save(payload))

    def test_access_and_provider_changes_during_read_prevent_commit(self):
        payload = self.payload()
        self.before_read = lambda: self.change("UPDATE qbo_connections SET authorized_at='replacement'")
        self.expect("grant_changed", lambda: self.save(payload))
        self.assertIsNone(self.context()["mapping"])
        self.before_read = lambda: None
        payload = self.payload()
        self.before_read = lambda: self.change("UPDATE auth_sessions SET revoked_at='now' WHERE id=?", (self.admin,))
        self.expect("administrator_required", lambda: self.save(payload))

    def test_stale_office_revision_cannot_overwrite_new_mapping(self):
        stale = self.payload()
        self.save()
        self.expect("mapping_changed", lambda: self.save(stale))

    def test_replay_after_a_later_disable_returns_current_not_stale_enabled_mapping(self):
        original = self.payload()
        self.save(original)
        disable = self.payload(enabled=False)
        self.save(disable)
        replay = self.save(original)
        self.assertTrue(replay["replayed"])
        self.assertEqual(replay["mapping"]["revision"], 2)
        self.assertFalse(replay["mapping"]["enabled"])
        self.assertFalse(replay["mapping"]["usable"])

    def test_reused_operation_id_cannot_change_worker_or_contents(self):
        payload = self.payload()
        self.save(payload)
        self.expect("operation_changed", lambda: self.save({**payload, "enabled": False}))
        self.expect("operation_changed", lambda: self.save({**payload, "workerEmail": "standard@example.invalid"}))

    def test_disabling_exact_original_mapping_needs_no_provider_read(self):
        self.save()
        payload = self.payload(enabled=False)
        self.remote["Active"] = False
        self.reads.clear()
        result = self.save(payload)
        self.assertFalse(result["mapping"]["enabled"])
        self.assertFalse(self.reads)

    def test_disabling_cannot_create_or_retarget_mapping(self):
        payload = self.payload(enabled=False)
        self.expect("mapping_changed", lambda: self.save(payload))
        self.save()
        payload = self.payload(enabled=False, providerID="different")
        self.expect("mapping_changed", lambda: self.save(payload))

    def test_one_quickbooks_worker_cannot_be_assigned_to_two_people(self):
        self.save()
        other = self.payload(workerEmail="standard@example.invalid", expectedRevision=0)
        self.expect("worker_identity_conflict", lambda: self.save(other))

    def test_two_simultaneous_exact_saves_share_one_revision(self):
        payload = self.payload()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.save(payload), range(2)))
        self.assertEqual([item["mapping"]["revision"] for item in results], [1, 1])
        self.assertEqual(sum(not item["replayed"] for item in results), 1)

    def test_mapping_contents_are_encrypted_and_integrity_checked(self):
        self.save()
        with backend.db() as connection:
            row = dict(connection.execute("SELECT * FROM time_worker_mappings").fetchone())
        self.assertNotIn("Taylor", row["payload_ciphertext"])
        self.assertNotIn("SSN", backend.decrypt_catalog_payload(row["payload_ciphertext"]))
        self.change("UPDATE time_worker_mappings SET payload_hash=?", ("0" * 64,))
        self.expect("storage_unavailable", self.context)

    def test_unknown_fields_bad_types_and_noncanonical_worker_values_rejected(self):
        payload = self.payload()
        invalid = ({"extra": 1}, {"expectedRevision": True}, {"expectedRevision": -1}, {"enabled": 1},
                   {"kind": "Customer"}, {"providerID": "../invoice"}, {"workerEmail": " Tech@example.invalid"},
                   {"referenceRevision": "bad"}, {"operationID": "invalid"}, {"connectionRevision": "A" * 64})
        for change in invalid:
            with self.assertRaises(workers.AttemptError):
                self.save({**payload, **change})

    def test_loopback_routes_require_session_and_reject_ambiguous_requests(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:" + str(server.server_port)
        def request(path, payload=None, *, token=None, raw=None):
            data = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
            headers = {"Authorization": "Bearer " + (token or self.tokens["Admin"]), "Content-Type": "application/json"}
            req = urllib.request.Request(base + path, data=data, headers=headers, method="POST" if data is not None else "GET")
            try:
                response = urllib.request.urlopen(req, timeout=5)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                return response.status, json.loads(response.read())
        try:
            path = "/api/time-worker-mappings"
            query = urllib.parse.urlencode({"companyID": self.company, "workerEmail": self.worker})
            self.assertEqual(request(path + "?" + query)[0], 200)
            candidate = query + "&kind=Employee&providerID=55"
            self.assertEqual(request(path + "/candidate?" + candidate)[0], 200)
            payload = self.payload()
            self.assertEqual(request(path, payload)[0], 200)
            self.assertEqual(request(path, payload, token=self.tokens["Accounting"])[0], 403)
            self.assertEqual(request(path + "?" + query, token=self.tokens["Field Technician"])[0], 403)
            self.assertEqual(request(path + "?" + query + "&workerEmail=other@example.invalid")[0], 400)
            self.assertEqual(request(path + "?" + query + "&url=https://example.invalid")[0], 400)
            self.assertEqual(request(path + "/", payload)[0], 404)
            self.assertEqual(request(path + "?force=true", payload)[0], 404)
            self.assertEqual(request(path, raw=b'{"companyID":"one","companyID":"two"}')[0], 400)
            self.assertEqual(request(path, payload, token="fixture-api-key")[0], 401)
            with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="fixture-api-key"):
                self.assertEqual(request(path, payload, token="fixture-api-key")[0], 403)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=5)

    def test_worker_email_and_provider_reference_are_redacted_from_http_logs(self):
        handler = mock.Mock()
        handler.address_string.return_value = "127.0.0.1"
        with mock.patch("builtins.print") as logged:
            backend.GunnAireBackendHandler.log_message(handler, '"%s" %s %s',
                "GET /api/time-worker-mappings/candidate?workerEmail=private%40example.invalid&providerID=private-id HTTP/1.1", "200", "-")
        output = str(logged.call_args)
        self.assertIn("/api/time-worker-mappings/[redacted]", output)
        self.assertNotIn("private", output)

    def test_another_office_save_during_provider_read_prevents_stale_commit(self):
        stale = self.payload()
        fresh = self.payload()
        def competing_save():
            self.before_read = lambda: None
            self.save(fresh)
        self.before_read = competing_save
        self.expect("mapping_changed", lambda: self.save(stale))
        self.assertEqual(self.context()["mapping"]["revision"], 1)

    def test_context_does_not_accept_provider_result_after_mapping_changes(self):
        fresh = self.payload()
        def competing_save():
            self.before_read = lambda: None
            self.save(fresh)
        self.before_read = competing_save
        self.expect("mapping_changed", lambda: self.context(candidate=True))
