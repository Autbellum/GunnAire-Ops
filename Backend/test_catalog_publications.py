from __future__ import annotations

import copy
import hashlib
import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from cryptography.fernet import Fernet

from Backend import gunnaire_backend as backend
from Backend import catalog_publications as catalog


class CatalogPublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.settings = mock.patch.multiple(
            backend, DATA_ROOT=root, DB_PATH=root / "catalog.sqlite3", STORAGE_ROOT=root / "files",
            AUTH_MODE="google-id-token", PRIMARY_ADMIN_EMAIL="owner@example.invalid",
            QBO_TOKEN_ENCRYPTION_KEY=Fernet.generate_key().decode(),
        )
        self.settings.start()
        backend.initialize_database()
        self.local_id = str(uuid.uuid4())
        self.tokens, self.sessions, self.remotes, self.writes = {}, {}, [], []
        self.before_read = lambda: None
        self.before_write = lambda: None
        self.after_write = lambda remote: remote
        with backend.db() as connection:
            self.company = connection.execute("SELECT company_id FROM company_identity").fetchone()[0]
            connection.execute("INSERT INTO qbo_connections VALUES (1,'realm','cipher','sandbox','client','grant','updated')")
            columns = [row[1] for row in connection.execute("PRAGMA table_info(qbo_accounting_config)")]
            values = {key: "" for key in columns}
            values.update(realm_id="realm", environment="sandbox", default_income_account_ref="income",
                          default_expense_account_ref="expense")
            connection.execute("INSERT INTO qbo_accounting_config (" + ",".join(columns) + ") VALUES (" +
                               ",".join("?" for _ in columns) + ")", tuple(values[key] for key in columns))
            for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
                email = role.lower().replace(" ", ".") + "@example.invalid"
                connection.execute("INSERT INTO users VALUES (?,?,1,?,?)", (email, role, backend.utc_now(), backend.utc_now()))
        for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
            self.tokens[role] = backend.create_app_session(role.lower().replace(" ", ".") + "@example.invalid", "google", "fixture")[0]
            with backend.db() as connection:
                self.sessions[role] = connection.execute("SELECT id FROM auth_sessions WHERE token_hash=?",
                    (backend.app_session_token_hash(self.tokens[role]),)).fetchone()[0]
        fixture = self
        class Provider:
            def __init__(self, context, authorize):
                self.authorize = authorize

            def items(self):
                values = copy.deepcopy(fixture.remotes)
                fixture.before_read()
                self.authorize()
                return values

            def read(self, entity, identifier):
                fixture.before_read()
                self.authorize()
                if entity == "vendor":
                    return {"Id": identifier, "Active": True}
                values = [remote for remote in fixture.remotes if remote["Id"] == identifier]
                if len(values) != 1:
                    raise catalog.failure("provider_unavailable", "Fixture item not found.", 502)
                return copy.deepcopy(values[0])

            def write(self, item, request_id, before_send):
                fixture.before_write()
                before_send()
                fixture.writes.append((copy.deepcopy(item), request_id))
                remote = {"Id": item.get("Id", "qbo-item"), "SyncToken": "1", "Active": True,
                          "Type": "Service", **copy.deepcopy(item)}
                remote["SyncToken"] = str(int(item.get("SyncToken", "0")) + 1)
                fixture.remotes = [remote]
                return fixture.after_write(copy.deepcopy(remote))
        self.provider_patch = mock.patch.object(backend, "CatalogQBOProvider", Provider)
        self.provider_patch.start()
        self.publisher = catalog.CatalogPublisher(backend.db, Provider, backend.encrypt_catalog_payload,
                                                  backend.decrypt_catalog_payload, backend.record_audit_event)
        self.admin = self.sessions["Admin"]

    def tearDown(self):
        self.provider_patch.stop()
        self.settings.stop()
        self.directory.cleanup()

    def payload(self, **changes):
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox",
                "localItemID": self.local_id, "operation": "create", "item": {
                    "Name": "HVAC service", "Type": "Service", "Sku": "HVAC-1", "UnitPrice": 125.5,
                    "PurchaseCost": 5, "Taxable": False, "IncomeAccountRef": {"value": "income"},
                    "ExpenseAccountRef": {"value": "expense"},
                }, **changes}

    def row(self):
        with backend.db() as connection:
            return dict(connection.execute("SELECT * FROM catalog_publications ORDER BY created_at DESC LIMIT 1").fetchone())

    def expect_code(self, code, function):
        with self.assertRaises(catalog.AttemptError) as caught:
            function()
        self.assertEqual(caught.exception.code, code)

    def publish(self, payload=None):
        return self.publisher.publish(self.admin, payload or self.payload())

    def test_create_replay_reads_current_provider_without_resending(self):
        first = self.publish()
        self.remotes[0]["UnitPrice"] = 140
        second = self.publish()
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(first["publication"]["id"], second["publication"]["id"])
        self.assertEqual(second["item"]["UnitPrice"], 140)
        self.assertEqual(self.writes[0][1], "ga-item-" + self.local_id)
        self.assertEqual(self.row()["state"], "confirmed")

    def test_payload_is_encrypted_and_public_status_omits_sensitive_internal_fields(self):
        result = self.publish()
        row = self.row()
        self.assertNotIn("HVAC", row["payload_ciphertext"])
        self.assertEqual(json.loads(backend.decrypt_catalog_payload(row["payload_ciphertext"]))["Name"], "HVAC service")
        public = json.dumps(result["publication"])
        for private in ("ciphertext", "grant_fingerprint", "actor_email", "request_id", "payload_hash", "session"):
            self.assertNotIn(private, public)

    def test_every_non_admin_role_is_denied_before_provider_access(self):
        for role in ("Accounting", "Dispatcher", "Field Technician", "Standard"):
            self.expect_code("administrator_required", lambda: self.publisher.publish(self.sessions[role], self.payload()))
        self.assertEqual(self.writes, [])
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM catalog_publications").fetchone()[0], 0)

    def test_primary_email_without_current_admin_record_has_no_bypass(self):
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard' WHERE role='Admin'")
        with mock.patch.object(backend, "PRIMARY_ADMIN_EMAIL", "admin@example.invalid"):
            self.expect_code("administrator_required", self.publish)

    def test_revoked_expired_missing_or_inactive_sessions_are_rejected(self):
        self.expect_code("administrator_required", lambda: self.publisher.publish("missing", self.payload()))
        for sql in ("UPDATE auth_sessions SET revoked_at='now'", "UPDATE auth_sessions SET expires_at='2000-01-01T00:00:00+00:00'",
                    "UPDATE users SET is_active=0"):
            with self.subTest(sql=sql), backend.db() as connection:
                connection.execute(sql)
            self.expect_code("administrator_required", self.publish)

    def test_company_realm_and_environment_must_match(self):
        for field, value, code in (("companyID", str(uuid.uuid4()), "company_changed"),
                                   ("realmID", "other", "provider_changed"), ("environment", "production", "provider_changed")):
            self.expect_code(code, lambda: self.publish(self.payload(**{field: value})))
        self.assertFalse(self.writes)

    def test_strict_fields_numbers_and_provider_name_limits(self):
        mutations = ({"Name": "Parent:Child"}, {"Name": "line\nbreak"}, {"Name": " "}, {"Name": "x" * 101},
                     {"PurchaseDesc": "x" * 1001}, {"Description": "x" * 4001}, {"Sku": "x" * 101},
                     {"UnitPrice": float("nan")}, {"UnitPrice": float("inf")}, {"PurchaseCost": -1},
                     {"UnitPrice": True}, {"UnitPrice": 100000000000}, {"Taxable": "false"},
                     {"Type": "Inventory"}, {"url": "https://example.invalid"},
                     {"IncomeAccountRef": {"value": "../other"}})
        for change in mutations:
            with self.subTest(change=repr(change)), self.assertRaises(catalog.AttemptError):
                payload = self.payload()
                payload["item"].update(change)
                self.publish(payload)
        self.assertFalse(self.writes)

    def test_supported_fractional_rates_are_not_rounded_to_cents(self):
        payload = self.payload()
        payload["item"]["UnitPrice"] = 0.0125
        self.assertEqual(self.publish(payload)["item"]["UnitPrice"], 0.0125)

    def test_inactive_exact_identity_is_recovered_without_creating(self):
        self.remotes = [{"Id": "inactive", "SyncToken": "3", "Active": False, **self.payload()["item"]}]
        self.assertEqual(self.publish()["item"]["Id"], "inactive")
        self.assertFalse(self.writes)

    def test_conflicting_name_sku_type_and_duplicate_matches_never_write(self):
        original = {"Id": "existing", "SyncToken": "0", "Active": True, **self.payload()["item"]}
        for change in ({"Sku": "OTHER"}, {"Type": "Inventory"}, {"Name": "different"}):
            self.remotes = [{**original, **change}]
            self.expect_code("identity_conflict", self.publish)
        self.remotes = [original, {**original, "Id": "second"}]
        self.expect_code("identity_conflict", self.publish)
        self.assertFalse(self.writes)

    def test_second_local_uuid_cannot_adopt_same_qbo_identity(self):
        self.publish()
        self.expect_code("identity_conflict", lambda: self.publish(self.payload(localItemID=str(uuid.uuid4()))))
        self.assertEqual(len(self.writes), 1)

    def test_changed_payload_cannot_replace_unknown_intent(self):
        self.after_write = lambda remote: (_ for _ in ()).throw(TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish()
        changed = self.payload()
        changed["item"]["UnitPrice"] = 300
        self.expect_code("publication_pending", lambda: self.publish(changed))
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.row()["state"], "unknown")

    def test_lost_response_recovers_after_publisher_restart_without_second_post(self):
        self.after_write = lambda remote: (_ for _ in ()).throw(TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish()
        row = self.row()
        replacement = catalog.CatalogPublisher(backend.db, backend.CatalogQBOProvider, backend.encrypt_catalog_payload,
                                                backend.decrypt_catalog_payload, backend.record_audit_event)
        result = replacement.run(self.admin, row["id"])
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)

    def test_unknown_absent_evidence_never_resends_or_cancels(self):
        self.after_write = lambda remote: (_ for _ in ()).throw(TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish()
        self.remotes = []
        self.expect_code("outcome_unknown", self.publish)
        self.expect_code("cannot_cancel", lambda: self.publisher.cancel(self.admin, self.row()["id"]))
        self.assertEqual(len(self.writes), 1)

    def test_crash_after_dispatch_claim_never_resends(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.publisher.claim(self.admin, row["id"])
        self.expect_code("outcome_unknown", self.publish)
        self.assertFalse(self.writes)

    def test_cancel_unsent_allows_explicit_corrected_proposal(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.publisher.cancel(self.admin, row["id"])
        changed = self.payload()
        changed["item"]["UnitPrice"] = 200
        self.assertEqual(self.publish(changed)["item"]["UnitPrice"], 200)
        self.assertEqual(len(self.writes), 1)

    def test_read_only_recovery_of_unsent_does_not_dispatch(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.expect_code("outcome_unknown", lambda: self.publisher.run(self.admin, row["id"]))
        self.assertFalse(self.writes)

    def test_two_devices_receive_only_one_dispatch(self):
        barrier = threading.Barrier(2)
        self.before_read = lambda: barrier.wait(timeout=5)
        def call():
            try:
                return self.publish()
            except catalog.AttemptError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: call(), range(2)))
        self.assertEqual(len(self.writes), 1)
        self.assertTrue(any(isinstance(value, dict) for value in results))
        self.assertEqual(self.row()["state"], "confirmed")

    def test_two_local_ids_cannot_reserve_the_same_name_or_sku_concurrently(self):
        self.publisher.reserve(self.admin, self.payload())
        self.expect_code("catalog_busy", lambda: self.publisher.reserve(self.admin, self.payload(localItemID=str(uuid.uuid4()))))

    def test_access_loss_during_preflight_prevents_dispatch(self):
        def revoke():
            with backend.db() as connection:
                connection.execute("UPDATE users SET is_active=0")
        self.before_read = revoke
        self.expect_code("administrator_required", self.publish)
        self.assertFalse(self.writes)

    def test_access_loss_after_provider_accepts_leaves_unknown(self):
        def revoke(remote):
            with backend.db() as connection:
                connection.execute("UPDATE users SET is_active=0")
            return remote
        self.after_write = revoke
        self.expect_code("administrator_required", self.publish)
        self.assertEqual(self.row()["state"], "unknown")

    def test_reconnected_grant_cannot_resume_original_attempt(self):
        row = self.publisher.reserve(self.admin, self.payload())
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='replacement'")
        self.expect_code("grant_changed", lambda: self.publisher.run(self.admin, row["id"]))
        self.assertFalse(self.writes)

    def test_account_mapping_change_at_dispatch_prevents_write(self):
        def change():
            with backend.db() as connection:
                connection.execute("UPDATE qbo_accounting_config SET default_income_account_ref='replacement'")
        self.before_write = change
        self.expect_code("account_mapping_changed", self.publish)
        self.assertEqual(self.row()["state"], "reserved")
        self.assertFalse(self.writes)

    def test_missing_encryption_prevents_reservation(self):
        with mock.patch.object(backend, "QBO_TOKEN_ENCRYPTION_KEY", ""):
            with self.assertRaises(RuntimeError):
                self.publish()
        self.assertFalse(self.writes)

    def test_tampered_encrypted_payload_is_rejected(self):
        row = self.publisher.reserve(self.admin, self.payload())
        with backend.db() as connection:
            item = self.payload()["item"]
            item["UnitPrice"] = 999
            connection.execute("UPDATE catalog_publications SET payload_ciphertext=?",
                               (backend.encrypt_catalog_payload(json.dumps(item)),))
        self.expect_code("storage_unavailable", lambda: self.publisher.run(self.admin, row["id"], allow_send=True))
        self.assertFalse(self.writes)

    def update_payload(self):
        original = self.publish()["item"]
        return self.payload(operation="update", item={
            "Id": original["Id"], "SyncToken": original["SyncToken"], "Name": "HVAC service", "sparse": True,
            "Active": True, "Description": "", "Sku": "HVAC-1", "PurchaseDesc": "", "UnitPrice": 200,
            "PurchaseCost": 5, "Taxable": False,
        })

    def test_update_requires_original_sync_token_and_immutable_request_id(self):
        payload = self.update_payload()
        result = self.publish(payload)
        self.assertEqual(result["item"]["UnitPrice"], 200)
        self.assertEqual(len(self.writes), 2)
        self.assertLessEqual(len(self.writes[-1][1]), 50)
        self.publish(payload)
        self.assertEqual(len(self.writes), 2)

    def test_changed_provider_version_requires_new_review(self):
        payload = self.update_payload()
        self.remotes[0]["SyncToken"] = "99"
        self.expect_code("review_changed", lambda: self.publish(payload))
        self.assertEqual(len(self.writes), 1)

    def test_unconfirmed_response_values_leave_unknown_and_do_not_link(self):
        self.after_write = lambda remote: {**remote, "UnitPrice": 900}
        self.expect_code("provider_unconfirmed", self.publish)
        self.assertEqual(self.row()["state"], "unknown")
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM catalog_entity_mappings").fetchone()[0], 0)

    def test_confirmation_save_failure_preserves_dispatch_record(self):
        actual = self.publisher.confirm
        self.publisher.confirm = mock.Mock(side_effect=sqlite3.OperationalError("fixture storage failure"))
        with self.assertRaises(sqlite3.OperationalError):
            self.publish()
        self.assertEqual(self.row()["state"], "unknown")
        self.publisher.confirm = actual
        self.publisher.run(self.admin, self.row()["id"])
        self.assertEqual(len(self.writes), 1)

    def test_schema_creation_does_not_commit_callers_transaction(self):
        with backend.db() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("UPDATE users SET is_active=0")
            catalog.initialize_schema(connection)
            connection.rollback()
            self.assertEqual(connection.execute("SELECT MIN(is_active) FROM users").fetchone()[0], 1)

    def test_reviewed_archive_and_reactivation_keep_the_original_provider_id(self):
        payload = self.update_payload()
        payload["item"]["Active"] = False
        archived = self.publish(payload)
        self.assertFalse(archived["item"]["Active"])
        payload["item"]["Active"] = True
        payload["item"]["SyncToken"] = archived["item"]["SyncToken"]
        restored = self.publish(payload)
        self.assertTrue(restored["item"]["Active"])
        self.assertEqual(restored["item"]["Id"], archived["item"]["Id"])
        self.assertEqual(len(self.writes), 3)

    def test_unknown_update_recovers_only_after_exact_proposed_values_are_visible(self):
        payload = self.update_payload()
        self.after_write = lambda remote: (_ for _ in ()).throw(TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish(payload)
        row = self.row()
        self.remotes[0]["UnitPrice"] = 1
        self.expect_code("review_changed", lambda: self.publisher.run(self.admin, row["id"]))
        self.assertEqual(self.row()["state"], "unknown")
        self.remotes[0]["UnitPrice"] = 200
        self.assertEqual(self.publisher.run(self.admin, row["id"])["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 2)

    def test_cancel_racing_dispatch_has_only_one_winner(self):
        row = self.publisher.reserve(self.admin, self.payload())
        barrier = threading.Barrier(2)
        def perform(action):
            barrier.wait(timeout=5)
            try:
                if action == "cancel":
                    self.publisher.cancel(self.admin, row["id"])
                else:
                    self.publisher.claim(self.admin, row["id"])
                return action
            except catalog.AttemptError:
                return "rejected"
        with ThreadPoolExecutor(max_workers=2) as pool:
            result = list(pool.map(perform, ["cancel", "claim"]))
        self.assertEqual(result.count("rejected"), 1)
        self.assertIn(self.row()["state"], ("cancelled", "sending"))
        self.assertFalse(self.writes)


    def test_http_contract_requires_application_session_and_supports_recovery(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def request(path, payload=None, token=None):
            req = urllib.request.Request("http://127.0.0.1:" + str(server.server_port) + path,
                data=json.dumps(payload).encode() if payload is not None else None,
                headers={"Authorization": "Bearer " + (token or self.tokens["Admin"]), "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=5) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)
        try:
            status, result = request("/api/catalog-publications", self.payload())
            self.assertEqual(status, 200, result)
            identifier = result["publication"]["id"]
            self.assertEqual(request("/api/catalog-publications/" + identifier + "/recover", {})[0], 200)
            path = "/api/catalog-publications?companyID=" + self.company + "&localItemID=" + self.local_id
            self.assertEqual(len(request(path)[1]["publications"]), 1)
            self.assertEqual(request(path, token=self.tokens["Standard"])[0], 403)
            self.assertEqual(request("/api/catalog-publications", {**self.payload(), "extra": 1})[0], 400)
            self.assertEqual(request("/api/catalog-publications/" + identifier + "/cancel", {})[0], 409)
            self.assertEqual(request("/api/catalog-publications/" + identifier + "/recover", {"force": True})[0], 400)
            with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="fixture-api-key"):
                self.assertEqual(request("/api/catalog-publications", self.payload(), token="fixture-api-key")[0], 403)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
