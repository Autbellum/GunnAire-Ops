from __future__ import annotations
import copy
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
from Backend import customer_publications as customer


class CustomerPublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.settings = mock.patch.multiple(backend, DATA_ROOT=root, DB_PATH=root / "customer.sqlite3", STORAGE_ROOT=root / "files",
            AUTH_MODE="google-id-token", PRIMARY_ADMIN_EMAIL="owner@example.invalid", QBO_TOKEN_ENCRYPTION_KEY=Fernet.generate_key().decode())
        self.settings.start()
        backend.initialize_database()
        self.local_id, self.tokens, self.sessions, self.remotes, self.writes = str(uuid.uuid4()), {}, {}, [], []
        self.before_read, self.before_write, self.after_write = lambda: None, lambda: None, lambda remote: remote
        with backend.db() as connection:
            self.company = connection.execute("SELECT company_id FROM company_identity").fetchone()[0]
            connection.execute("INSERT INTO qbo_connections VALUES (1,'realm','cipher','sandbox','client','grant','updated')")
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

            def customers(self):
                values = copy.deepcopy(fixture.remotes)
                fixture.before_read()
                self.authorize()
                return values

            def read(self, identifier):
                fixture.before_read()
                self.authorize()
                values = [remote for remote in fixture.remotes if remote["Id"] == identifier]
                if len(values) != 1:
                    raise customer.failure("provider_unavailable", "Fixture customer not found.", 502)
                return copy.deepcopy(values[0])

            def write(self, payload, request_id, before_send):
                fixture.before_write()
                before_send()
                fixture.writes.append((copy.deepcopy(payload), request_id))
                remote = {"Id": "qbo-customer", "SyncToken": "0", "Active": True, **copy.deepcopy(payload)}
                fixture.remotes = [remote]
                return fixture.after_write(copy.deepcopy(remote))
        self.provider_patch = mock.patch.object(backend, "CustomerQBOProvider", Provider)
        self.provider_patch.start()
        self.publisher = customer.CustomerPublisher(backend.db, Provider, backend.encrypt_catalog_payload,
            backend.decrypt_catalog_payload, backend.record_audit_event)
        self.admin = self.sessions["Admin"]

    def tearDown(self):
        self.provider_patch.stop()
        self.settings.stop()
        self.directory.cleanup()

    def payload(self, **changes):
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox", "localCustomerID": self.local_id,
            "customer": {"DisplayName": "Taylor Customer", "PrimaryPhone": {"FreeFormNumber": "(919) 555-0123"},
                         "PrimaryEmailAddr": {"Address": "taylor@example.invalid"}, "BillAddr": {"Line1": "42 Fixture Street"}}, **changes}

    def publish(self, payload=None):
        return self.publisher.publish(self.admin, payload or self.payload())

    def row(self):
        with backend.db() as connection:
            return dict(connection.execute("SELECT * FROM customer_publications ORDER BY created_at DESC LIMIT 1").fetchone())

    def expect_code(self, code, function):
        with self.assertRaises(customer.AttemptError) as caught:
            function()
        self.assertEqual(caught.exception.code, code)

    def remote(self, **changes):
        return {"Id": "existing", "SyncToken": "2", "Active": True, **self.payload()["customer"], **changes}

    def test_original_customer_is_created_once_with_stable_lineage_and_request_id(self):
        first, second = self.publish(), self.publish()
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(first["publication"]["id"], second["publication"]["id"])
        self.assertEqual(self.writes[0][1], "ga-customer-" + self.local_id)
        self.assertLessEqual(len(self.writes[0][1]), 50)
        self.assertEqual(self.writes[0][0]["Notes"], customer.lineage(self.local_id))

    def test_changed_proposal_after_confirmation_recovers_current_customer_without_recreating(self):
        self.publish()
        self.remotes[0]["DisplayName"] = "Renamed Customer"
        self.remotes[0]["Active"] = False
        payload = self.payload(customer={"DisplayName": "New Local Name"})
        result = self.publish(payload)
        self.assertEqual(result["customer"]["DisplayName"], "Renamed Customer")
        self.assertFalse(result["customer"]["Active"])
        self.assertFalse(result["created"])
        self.assertEqual(len(self.writes), 1)

    def test_encrypted_payload_and_public_metadata_do_not_expose_contacts(self):
        result = self.publish()
        row = self.row()
        self.assertNotIn("Taylor", row["payload_ciphertext"])
        self.assertEqual(json.loads(backend.decrypt_catalog_payload(row["payload_ciphertext"])), self.payload()["customer"])
        for private in ("Taylor", "taylor@", "actor_email", "request_id", "payload_hash", "grant_fingerprint", "ciphertext"):
            self.assertNotIn(private, json.dumps(result["publication"]))

    def test_customer_response_omits_provider_tax_balance_and_private_notes(self):
        self.remotes = [self.remote(PrimaryTaxIdentifier="fixture-tax", Balance=999, Notes="Private provider notes")]
        result = self.publish()
        self.assertEqual(set(result["customer"]), {"Id", "DisplayName", "Active", "PrimaryPhone", "PrimaryEmailAddr", "BillAddr"})
        self.assertNotIn("fixture-tax", json.dumps(result))
        self.assertNotIn("Private provider notes", json.dumps(result))

    def test_non_admin_roles_cannot_publish_or_list_company_customers(self):
        for role in ("Accounting", "Dispatcher", "Field Technician", "Standard"):
            self.expect_code("administrator_required", lambda: self.publisher.publish(self.sessions[role], self.payload()))
            self.expect_code("administrator_required", lambda: self.publisher.list_for_customer(self.sessions[role], self.company, self.local_id))
        self.assertFalse(self.writes)

    def test_missing_inactive_revoked_expired_and_future_sessions_do_not_authorize(self):
        self.expect_code("administrator_required", lambda: self.publisher.publish("missing", self.payload()))
        with backend.db() as connection:
            original = dict(connection.execute("SELECT * FROM auth_sessions WHERE id=?", (self.admin,)).fetchone())
        for sql in ("UPDATE auth_sessions SET created_at='2999-01-01T00:00:00+00:00'", "UPDATE auth_sessions SET expires_at='2000-01-01T00:00:00+00:00'",
                    "UPDATE auth_sessions SET revoked_at='now'", "UPDATE users SET is_active=0"):
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET created_at=?,expires_at=?,revoked_at=NULL",
                                   (original["created_at"], original["expires_at"]))
                connection.execute("UPDATE users SET is_active=1")
                connection.execute(sql)
            self.expect_code("administrator_required", self.publish)
        self.assertFalse(self.writes)

    def test_primary_email_is_not_an_administrator_bypass(self):
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard'")
        with mock.patch.object(backend, "PRIMARY_ADMIN_EMAIL", "admin@example.invalid"):
            self.expect_code("administrator_required", self.publish)

    def test_company_realm_and_environment_are_exact(self):
        for field, value, code in (("companyID", str(uuid.uuid4()), "company_changed"), ("realmID", "other", "provider_changed"),
                                   ("environment", "production", "provider_changed")):
            self.expect_code(code, lambda: self.publish(self.payload(**{field: value})))
        self.assertFalse(self.writes)

    def test_strict_contact_fields_reject_financial_updates_and_arbitrary_urls(self):
        for change in ({"DisplayName": " "}, {"DisplayName": "A:B"}, {"DisplayName": "line\nbreak"}, {"DisplayName": "x" * 501},
                       {"PrimaryPhone": {"FreeFormNumber": "x" * 31}}, {"PrimaryEmailAddr": {"Address": "bad"}},
                       {"BillAddr": {"Line1": "x" * 501}}, {"Active": False}, {"Balance": 5}, {"Id": "other"},
                       {"SyncToken": "0"}, {"Notes": "forged"}, {"url": "https://example.invalid"}, {"ParentRef": {"value": "other"}},
                       {"PrimaryPhone": None}, {"DisplayName": float("nan")}):
            payload = self.payload()
            payload["customer"].update(change)
            with self.subTest(change=change), self.assertRaises(customer.AttemptError):
                self.publish(payload)
        self.assertFalse(self.writes)

    def test_existing_compatible_active_or_inactive_customer_links_without_post(self):
        self.remotes = [self.remote(Active=False, PrimaryPhone={"FreeFormNumber": "+1 9195550123"})]
        result = self.publish()
        self.assertEqual(result["customer"]["Id"], "existing")
        self.assertFalse(result["customer"]["Active"])
        self.assertFalse(self.writes)

    def test_ambiguous_conflicting_and_foreign_lineage_customers_do_not_link(self):
        self.remotes = [self.remote(), self.remote(Id="other")]
        self.expect_code("identity_conflict", self.publish)
        self.remotes = [self.remote(PrimaryPhone={"FreeFormNumber": "9195550000"})]
        self.expect_code("provider_unconfirmed", self.publish)
        self.remotes = [self.remote(Notes=customer.lineage(str(uuid.uuid4())))]
        self.expect_code("identity_conflict", self.publish)
        self.assertFalse(self.writes)

    def test_second_local_uuid_cannot_adopt_provider_customer(self):
        self.remotes = [self.remote()]
        self.publish()
        self.expect_code("identity_conflict", lambda: self.publish(self.payload(localCustomerID=str(uuid.uuid4()))))
        self.assertFalse(self.writes)

    def test_name_key_serializes_distinct_local_proposals(self):
        self.publisher.reserve(self.admin, self.payload())
        self.expect_code("customer_busy", lambda: self.publisher.reserve(self.admin, self.payload(localCustomerID=str(uuid.uuid4()))))
        self.assertFalse(self.writes)

    def test_lost_response_recovers_original_lineage_after_restart(self):
        self.after_write = mock.Mock(side_effect=TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish()
        self.assertEqual(self.row()["state"], "unknown")
        restarted = customer.CustomerPublisher(backend.db, backend.CustomerQBOProvider, backend.encrypt_catalog_payload,
            backend.decrypt_catalog_payload, backend.record_audit_event)
        result = restarted.run(self.admin, self.row()["id"])
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)

    def test_unknown_name_only_result_is_not_enough_to_claim_original_outcome(self):
        self.after_write = mock.Mock(side_effect=TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish()
        self.remotes[0].pop("Notes")
        self.expect_code("provider_unconfirmed", self.publish)
        self.assertEqual(self.row()["state"], "unknown")
        self.assertEqual(len(self.writes), 1)

    def test_unknown_absent_result_never_resends_or_cancels(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.publisher.claim(self.admin, row["id"])
        self.expect_code("outcome_unknown", self.publish)
        self.expect_code("cannot_cancel", lambda: self.publisher.cancel(self.admin, row["id"]))
        self.assertFalse(self.writes)

    def test_changed_pending_payload_requires_review_not_replacement(self):
        self.publisher.reserve(self.admin, self.payload())
        self.expect_code("publication_pending", lambda: self.publish(self.payload(customer={"DisplayName": "Changed"})))
        self.assertEqual(json.loads(backend.decrypt_catalog_payload(self.row()["payload_ciphertext"]))["DisplayName"], "Taylor Customer")

    def test_cancel_only_unsent_proposal_preserves_local_identity_for_corrected_retry(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.publisher.cancel(self.admin, row["id"])
        self.expect_code("cancelled", lambda: self.publisher.run(self.admin, row["id"]))
        self.publish(self.payload(customer={"DisplayName": "Corrected"}))
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.writes[0][1], "ga-customer-" + self.local_id)

    def test_missing_encryption_and_tampered_payload_prevent_dispatch(self):
        with mock.patch.object(backend, "QBO_TOKEN_ENCRYPTION_KEY", ""), self.assertRaises(RuntimeError):
            self.publish()
        row = self.publisher.reserve(self.admin, self.payload())
        with backend.db() as connection:
            connection.execute("UPDATE customer_publications SET payload_ciphertext=?", (backend.encrypt_catalog_payload('{"DisplayName":"Tampered"}'),))
        self.expect_code("storage_unavailable", lambda: self.publisher.run(self.admin, row["id"], allow_send=True))
        self.assertFalse(self.writes)

    def test_reconnected_grant_cannot_resume_or_cancel_original_attempt(self):
        row = self.publisher.reserve(self.admin, self.payload())
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='new-grant'")
        self.expect_code("grant_changed", self.publish)
        self.expect_code("grant_changed", lambda: self.publisher.cancel(self.admin, row["id"]))
        self.assertFalse(self.writes)

    def test_access_loss_immediately_before_send_stops_dispatch(self):
        def revoke():
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at='now'")
        self.before_write = revoke
        self.expect_code("administrator_required", self.publish)
        self.assertEqual(self.row()["state"], "reserved")
        self.assertFalse(self.writes)

    def test_access_loss_after_customer_census_prevents_dispatch(self):
        def revoke():
            with backend.db() as connection:
                connection.execute("UPDATE users SET is_active=0")
        self.before_read = revoke
        self.expect_code("administrator_required", self.publish)
        self.assertEqual(self.row()["state"], "reserved")
        self.assertFalse(self.writes)

    def test_late_role_loss_does_not_confirm_provider_write(self):
        def revoke(remote):
            with backend.db() as connection:
                connection.execute("UPDATE users SET role='Standard'")
            return remote
        self.after_write = revoke
        self.expect_code("administrator_required", self.publish)
        self.assertEqual(self.row()["state"], "unknown")

    def test_partial_response_contact_or_lineage_remains_unknown(self):
        self.after_write = lambda remote: {key: value for key, value in remote.items() if key != "PrimaryPhone"}
        self.expect_code("provider_unconfirmed", self.publish)
        self.assertEqual(self.row()["state"], "unknown")
        self.assertEqual(len(self.writes), 1)

    def test_confirmation_save_failure_recovers_without_second_post(self):
        with mock.patch.object(self.publisher, "confirm", side_effect=sqlite3.OperationalError("fixture")), self.assertRaises(sqlite3.Error):
            self.publish()
        self.assertEqual(self.row()["state"], "unknown")
        self.publisher.run(self.admin, self.row()["id"])
        self.assertEqual(len(self.writes), 1)

    def test_transactional_audit_failure_rolls_back_confirmation_and_mapping(self):
        original = self.publisher.audit
        def audit(actor, action, *args, **kwargs):
            if action == "confirm":
                raise sqlite3.OperationalError("fixture audit unavailable")
            original(actor, action, *args, **kwargs)
        self.publisher.audit = audit
        with self.assertRaises(sqlite3.Error):
            self.publish()
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM customer_entity_mappings").fetchone()[0], 0)
        self.assertEqual(self.row()["state"], "unknown")

    def test_concurrent_devices_dispatch_only_once(self):
        barrier = threading.Barrier(2)
        self.before_write = lambda: barrier.wait(timeout=5)
        def publish(_):
            try:
                return self.publish()["publication"]["state"]
            except customer.AttemptError:
                return "review"
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(publish, range(2)))
        self.assertIn("confirmed", outcomes)
        self.assertEqual(len(self.writes), 1)

    def test_cancel_dispatch_race_has_only_one_winner(self):
        row = self.publisher.reserve(self.admin, self.payload())
        barrier = threading.Barrier(2)
        def perform(action):
            barrier.wait(timeout=5)
            try:
                (self.publisher.cancel if action == "cancel" else self.publisher.claim)(self.admin, row["id"])
                return action
            except customer.AttemptError:
                return "rejected"
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(perform, ("cancel", "claim")))
        self.assertEqual(outcomes.count("rejected"), 1)

    def test_additive_schema_does_not_commit_an_outer_transaction(self):
        with backend.db() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("UPDATE users SET is_active=0")
            customer.initialize_schema(connection)
            connection.rollback()
            self.assertEqual(connection.execute("SELECT MIN(is_active) FROM users").fetchone()[0], 1)

    def test_http_contract_scopes_session_list_recovery_and_cancellation(self):
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
            route = "/api/customer-publications"
            status, result = request(route, self.payload())
            self.assertEqual(status, 200, result)
            identifier = result["publication"]["id"]
            self.assertEqual(request(route + "/" + identifier + "/recover", {})[0], 200)
            self.assertEqual(request(route + "/" + identifier + "/cancel", {})[0], 409)
            self.assertEqual(request(route + "?companyID=" + self.company + "&localCustomerID=" + self.local_id)[0], 200)
            for path, payload in ((route + "?companyID=x", None), (route + "/" + identifier + "/send", {}),
                                  (route, {"customer": "bad"}), (route + "?extra=1", self.payload())):
                self.assertIn(request(path, payload)[0], (400, 404))
            self.assertEqual(request(route, self.payload(), self.tokens["Field Technician"])[0], 403)
            self.assertEqual(request(route, self.payload(), "not-a-session")[0], 401)
            self.assertEqual(len(self.writes), 1)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
