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
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import payment_attempts as attempts


class PaymentAttemptTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.settings = mock.patch.multiple(
            backend, DATA_ROOT=root, DB_PATH=root / "test.sqlite3", STORAGE_ROOT=root / "files",
            AUTH_MODE="google-id-token", PRIMARY_ADMIN_EMAIL="owner@example.invalid",
        )
        self.settings.start()
        backend.initialize_database()
        self.invoice_id = str(uuid.uuid4())
        self.tokens, self.sessions = {}, {}
        with backend.db() as connection:
            self.company_id = connection.execute("SELECT company_id FROM company_identity").fetchone()[0]
            connection.execute(
                """INSERT INTO qbo_connections VALUES
                   (1,'fixture-realm','fixture-ciphertext','sandbox','fixture-client','fixture-grant','fixture-updated')"""
            )
            for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
                email = role.lower().replace(" ", ".") + "@example.invalid"
                connection.execute(
                    "INSERT INTO users VALUES (?, ?, 1, ?, ?)", (email, role, backend.utc_now(), backend.utc_now()),
                )
        for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
            self.tokens[role] = backend.create_app_session(role.lower().replace(" ", ".") + "@example.invalid", "google", "fixture-" + role)[0]
            with backend.db() as connection:
                self.sessions[role] = connection.execute(
                    "SELECT id FROM auth_sessions WHERE token_hash=?", (backend.app_session_token_hash(self.tokens[role]),),
                ).fetchone()[0]
        self.invoice = {"Id": "fixture-invoice", "Balance": 100, "TotalAmt": 100,
                        "CustomerRef": {"value": "fixture-customer"}, "CurrencyRef": {"value": "USD"}}
        self.transactions = {}
        self.accounting = {}
        self.reads = []
        self.reader = mock.patch.object(backend, "read_payment_provider_record", side_effect=self.provider)
        self.reader.start()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:" + str(self.server.server_port)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.reader.stop()
        self.settings.stop()
        self.directory.cleanup()

    def provider(self, context, category, record_id, **kwargs):
        self.reads.append((category, record_id, kwargs))
        if category == "invoice":
            return copy.deepcopy(self.invoice)
        if category == "transaction":
            if record_id not in self.transactions:
                raise attempts.AttemptError("provider_unavailable", "Fixture record not found.", 502)
            return copy.deepcopy(self.transactions[record_id])
        return copy.deepcopy(self.accounting[record_id])

    def request(self, path="/api/payment-attempts", *, payload=None, role="Admin", method=None, token=None):
        request = urllib.request.Request(
            self.url + path, method=method or ("POST" if payload is not None else "GET"),
            data=json.dumps(payload).encode() if payload is not None else None,
            headers={"Authorization": "Bearer " + (token or self.tokens[role]), "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def payload(self, **changes):
        return {
            "id": str(uuid.uuid4()), "companyID": self.company_id,
            "realmID": "fixture-realm", "environment": "sandbox", "invoiceID": self.invoice_id,
            "invoiceQuickBooksID": "fixture-invoice", "customerQuickBooksID": "fixture-customer",
            "amountCents": 4000, "rail": "card", "kind": "charge", **changes,
        }

    def reserve(self, role="Admin", **changes):
        status, body = self.request(payload=self.payload(**changes), role=role)
        self.assertEqual(status, 200, body)
        return body["attempt"]

    def action(self, attempt, action, payload=None, role="Admin"):
        return self.request("/api/payment-attempts/" + attempt["id"] + "/" + action,
                            payload={} if payload is None else payload, role=role)

    def get(self, attempt, role="Admin"):
        return self.request("/api/payment-attempts/" + attempt["id"], role=role)

    def seed_provider(self, attempt, provider_id="fixture-charge", **changes):
        self.transactions[provider_id] = {
            "id": provider_id, "amount": str(attempt["amountCents"] / 100), "currency": "USD",
            "status": "CAPTURED" if attempt["kind"] == "charge" else "REFUNDED",
            "context": {"clientTransID": attempt["clientTransactionID"]}, **changes,
        }
        return provider_id

    def seed_accounting(self, attempt, accounting_id="fixture-accounting", **changes):
        self.accounting[accounting_id] = {
            "Id": accounting_id, "CustomerRef": {"value": "fixture-customer"},
            "TotalAmt": attempt["amountCents"] / 100,
            "PrivateNote": ("GunnAire payment ID: " + attempt["id"]) if attempt["kind"] == "charge" else
                ("Client transaction ID: " + attempt["clientTransactionID"]),
            "Line": [{"Amount": attempt["amountCents"] / 100,
                      "LinkedTxn": [{"TxnId": "fixture-invoice", "TxnType": "Invoice", "TxnLineId": "0"}]}],
            **changes,
        }
        return accounting_id

    def assignment(self):
        with backend.db() as connection:
            connection.execute(
                """INSERT INTO field_payment_assignments
                   (id,invoice_id,customer_name,amount,assigned_to,assigned_by,status,created_at)
                   VALUES (?,?,?,100,?,?,'accepted',?)""",
                (str(uuid.uuid4()), self.invoice_id, "Fixture customer",
                 "field.technician@example.invalid", "admin@example.invalid", backend.utc_now()),
            )

    def count(self):
        with backend.db() as connection:
            return connection.execute("SELECT COUNT(*) FROM payment_attempts").fetchone()[0]

    def test_reservation_is_durable_immutable_and_contains_no_payment_details(self):
        payload = self.payload()
        status, body = self.request(payload=payload)
        self.assertEqual(status, 200)
        attempt = body["attempt"]
        backend.initialize_database()
        self.assertEqual(self.get(attempt)[1]["attempt"], attempt)
        self.assertEqual(self.request(payload=payload)[1]["attempt"]["requestID"], attempt["requestID"])
        self.assertEqual(self.request(payload={**payload, "amountCents": 4100})[0], 409)
        self.assertEqual(self.count(), 1)
        self.assertEqual(attempt["state"], "reserved")
        self.assertNotIn("actor_session_id", str(body))
        self.assertNotIn("fixture-ciphertext", str(body))
        self.assertNotIn("grant_fingerprint", str(body))

    def test_two_devices_cannot_reserve_different_attempts_for_the_same_provider_invoice(self):
        barrier = threading.Barrier(2)
        def read(context, category, record_id, **kwargs):
            if category == "invoice":
                barrier.wait(timeout=5)
            return self.provider(context, category, record_id, **kwargs)
        with mock.patch.object(backend, "read_payment_provider_record", side_effect=read):
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda value: self.request(payload=value),
                                        [self.payload(), self.payload(invoiceID=str(uuid.uuid4()))]))
        self.assertEqual(sorted(status for status, _ in results), [200, 409])
        self.assertEqual(self.count(), 1)

    def test_concurrent_replay_of_same_reservation_returns_one_stable_request_id(self):
        payload = self.payload()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.request(payload=payload), range(2)))
        self.assertEqual([status for status, _ in results], [200, 200])
        self.assertEqual(len({body["attempt"]["requestID"] for _, body in results}), 1)
        self.assertEqual(self.count(), 1)

    def test_dispatch_permit_is_one_time_and_never_expires_into_another_send(self):
        attempt = self.reserve()
        self.assertEqual(self.action(attempt, "begin")[0], 200)
        backend.initialize_database()
        self.assertEqual(self.get(attempt)[1]["attempt"]["state"], "sending")
        self.assertEqual(self.action(attempt, "begin")[0], 409)
        self.assertEqual(self.action(attempt, "cancel")[0], 409)
        self.assertEqual(self.action(attempt, "unknown")[1]["attempt"]["state"], "unknown")
        self.assertEqual(self.request(payload=self.payload())[0], 409)
        self.assertEqual(self.action(attempt, "begin")[0], 409)
        self.assertEqual(self.count(), 1)

    def test_only_an_undispatched_reservation_can_be_cancelled(self):
        attempt = self.reserve()
        self.assertEqual(self.action(attempt, "cancel")[1]["attempt"]["state"], "cancelled")
        self.assertEqual(self.action(attempt, "cancel")[0], 200)
        self.assertEqual(self.action(attempt, "begin")[0], 409)
        self.assertEqual(self.request(payload=self.payload())[0], 200)

    def test_no_client_assertion_can_confirm_a_provider_transaction(self):
        attempt = self.reserve()
        self.action(attempt, "begin")
        for changes in (
            {"context": None}, {"context": {"clientTransID": "wrong-attempt"}},
            {"amount": "40.01"}, {"amount": True}, {"amount": "1e99999999"},
            {"currency": "EUR"}, {"status": "DECLINED"}, {"status": None},
            {"id": "another-id"},
        ):
            with self.subTest(changes=changes):
                self.seed_provider(attempt, **changes)
                status, _ = self.action(attempt, "confirm", {"providerID": "fixture-charge"})
                self.assertEqual(status, 409)
                stored = self.get(attempt)[1]["attempt"]
                self.assertEqual(stored["state"], "sending")
                self.assertIsNone(stored["providerID"])
                self.assertEqual(stored["candidateProviderID"], "fixture-charge")

    def test_confirmation_and_accounting_must_match_before_the_invoice_is_released(self):
        attempt = self.reserve()
        self.action(attempt, "begin")
        provider_id = self.seed_provider(attempt)
        status, body = self.action(attempt, "confirm", {"providerID": provider_id})
        self.assertEqual(status, 200, body)
        self.assertEqual(body["attempt"]["state"], "confirmed")
        self.assertEqual(self.request(payload=self.payload())[0], 409)
        accounting_id = self.seed_accounting(attempt, PrivateNote="another payment")
        self.assertEqual(self.action(attempt, "complete", {"accountingID": accounting_id})[0], 409)
        self.seed_accounting(attempt)
        self.assertEqual(self.action(attempt, "complete", {"accountingID": accounting_id})[1]["attempt"]["state"], "completed")
        self.assertEqual(self.action(attempt, "complete", {"accountingID": accounting_id})[0], 200)
        # Provider invoice still reports a stale $100. The retained ceiling
        # permits only $60 after the confirmed $40 collection.
        self.assertEqual(self.request(payload=self.payload(amountCents=6001))[0], 409)
        self.assertEqual(self.request(payload=self.payload(amountCents=6000))[0], 200)

    def test_confirm_replay_cannot_reduce_the_balance_twice(self):
        attempt = self.reserve()
        self.action(attempt, "begin")
        self.seed_provider(attempt)
        self.assertEqual(self.action(attempt, "confirm", {"providerID": "fixture-charge"})[0], 200)
        self.assertEqual(self.action(attempt, "confirm", {"providerID": "fixture-charge"})[0], 200)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT balance_ceiling_cents FROM payment_invoice_limits").fetchone()[0], 6000)

    def test_financial_access_is_rechecked_after_provider_read(self):
        for action in ("reserve", "confirm", "complete"):
            with self.subTest(action=action):
                with backend.db() as connection:
                    connection.execute("UPDATE users SET role='Admin' WHERE email='admin@example.invalid'")
                attempt = None
                if action != "reserve":
                    attempt = self.reserve()
                    self.action(attempt, "begin")
                    self.seed_provider(attempt)
                    if action == "complete":
                        self.action(attempt, "confirm", {"providerID": "fixture-charge"})
                        self.seed_accounting(attempt)
                def demote(context, category, record_id, **kwargs):
                    value = self.provider(context, category, record_id, **kwargs)
                    with backend.db() as connection:
                        connection.execute("UPDATE users SET role='Standard' WHERE email='admin@example.invalid'")
                    return value
                with mock.patch.object(backend, "read_payment_provider_record", side_effect=demote):
                    if action == "reserve":
                        status, _ = self.request(payload=self.payload())
                    else:
                        status, _ = self.action(attempt, action,
                            {"providerID": "fixture-charge"} if action == "confirm" else {"accountingID": "fixture-accounting"})
                self.assertEqual(status, 403)
                with backend.db() as connection:
                    if attempt:
                        row = connection.execute("SELECT state FROM payment_attempts WHERE id=?", (attempt["id"],)).fetchone()
                        self.assertEqual(row[0], "sending" if action == "confirm" else "confirmed")
                    connection.execute("DELETE FROM payment_attempts")
                    connection.execute("DELETE FROM payment_invoice_limits")

    def test_revoked_expired_and_changed_company_sessions_cannot_dispatch(self):
        attempt = self.reserve()
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE id=?", (backend.utc_now(), self.sessions["Admin"]))
        self.assertIn(self.action(attempt, "begin")[0], (401, 403))
        self.assertEqual(self.get(attempt, role="Accounting")[1]["attempt"]["state"], "reserved")
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET revoked_at=NULL, expires_at=? WHERE id=?",
                               ((datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat(), self.sessions["Admin"]))
        self.assertIn(self.action(attempt, "begin")[0], (401, 403))
        with backend.db() as connection:
            connection.execute("UPDATE company_identity SET company_id=?", (str(uuid.uuid4()),))
        self.assertEqual(self.action(attempt, "begin", role="Accounting")[0], 403)

    def test_technicians_need_an_active_assignment_and_cannot_issue_refunds(self):
        self.assertEqual(self.request(payload=self.payload(), role="Field Technician")[0], 403)
        self.assertEqual(self.request(payload=self.payload(), role="Dispatcher")[0], 403)
        self.assertEqual(self.request(payload=self.payload(), role="Standard")[0], 403)
        self.assertEqual(self.reads, [])
        self.assignment()
        attempt = self.reserve(role="Field Technician")
        with backend.db() as connection:
            connection.execute("UPDATE field_payment_assignments SET status='cancelled'")
        self.assertEqual(self.action(attempt, "begin", role="Field Technician")[0], 403)
        self.assertEqual(self.action(attempt, "cancel", role="Admin")[0], 200)
        refund = self.payload(kind="refund", sourcePaymentID=str(uuid.uuid4()),
                              sourceProviderID="fixture-original", sourceAccountingID="fixture-original-accounting")
        self.assertEqual(self.request(payload=refund, role="Field Technician")[0], 403)

    def test_changed_provider_grant_cannot_dispatch_but_rotation_within_grant_can(self):
        attempt = self.reserve()
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET refresh_token_ciphertext='fixture-rotated'")
        self.assertEqual(self.action(attempt, "begin")[0], 200)
        self.seed_provider(attempt)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='fixture-new-authorization'")
        self.assertEqual(self.action(attempt, "confirm", {"providerID": "fixture-charge"})[0], 409)
        self.assertEqual(self.get(attempt)[1]["attempt"]["state"], "sending")

    def test_failed_confirmation_retains_the_candidate_id_and_does_not_release_the_lock(self):
        attempt = self.reserve()
        self.action(attempt, "begin")
        status, _ = self.action(attempt, "confirm", {"providerID": "fixture-lost-response"})
        self.assertEqual(status, 502)
        backend.initialize_database()
        stored = self.get(attempt)[1]["attempt"]
        self.assertEqual(stored["candidateProviderID"], "fixture-lost-response")
        self.assertIsNone(stored["providerID"])
        self.assertEqual(stored["state"], "sending")
        self.assertEqual(self.request(payload=self.payload())[0], 409)

    def test_invalid_and_sensitive_payload_fields_are_rejected_before_provider_reads(self):
        for fields in ({"amountCents": True}, {"amountCents": 0}, {"amountCents": -1},
                       {"amountCents": 1.5}, {"amountCents": 100_000_001},
                       {"invoiceQuickBooksID": "../other"}, {"invoiceQuickBooksID": ".."},
                       {"cardNumber": "DO-NOT-STORE"}, {"token": "DO-NOT-STORE"},
                       {"companyID": str(uuid.uuid4())}):
            with self.subTest(fields=fields):
                status, body = self.request(payload=self.payload(**fields))
                self.assertIn(status, (400, 403), body)
                self.assertNotIn("DO-NOT-STORE", str(body))
        self.assertEqual(self.reads, [])
        self.assertEqual(self.count(), 0)

    def test_an_audit_failure_rolls_back_the_dispatch_permit(self):
        attempt = self.reserve()
        with mock.patch.object(backend, "record_audit_event", side_effect=RuntimeError("fixture audit failure")):
            self.assertEqual(self.action(attempt, "begin")[0], 503)
        self.assertEqual(self.get(attempt)[1]["attempt"]["state"], "reserved")
        self.assertEqual(self.action(attempt, "begin")[0], 200)

    def test_legacy_shared_api_token_cannot_use_the_journal(self):
        with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="fixture-shared-admin"):
            self.assertEqual(self.request(payload=self.payload(), token="fixture-shared-admin")[0], 403)
        self.assertEqual(self.count(), 0)

    def test_refund_requires_matching_original_provider_and_accounting_evidence(self):
        original = self.payload(amountCents=10000)
        self.transactions["fixture-original"] = {
            "id": "fixture-original", "amount": "100.00", "currency": "USD", "status": "CAPTURED",
            "context": {"clientTransID": "ga-charge-" + original["id"]},
        }
        self.seed_accounting({**original, "clientTransactionID": "ga-charge-" + original["id"]},
                             accounting_id="fixture-original-accounting")
        payload = self.payload(kind="refund", sourcePaymentID=original["id"],
            sourceProviderID="fixture-original", sourceAccountingID="fixture-original-accounting")
        status, body = self.request(payload=payload, role="Accounting")
        self.assertEqual(status, 200, body)
        attempt = body["attempt"]
        self.assertEqual(self.action(attempt, "begin", role="Accounting")[0], 200)
        self.seed_provider(attempt, provider_id="fixture-refund", status="REFUNDED")
        self.assertEqual(self.action(attempt, "confirm", {"providerID": "fixture-refund"}, role="Accounting")[0], 200)
        self.seed_accounting(attempt, accounting_id="fixture-refund-receipt")
        self.assertEqual(self.action(attempt, "complete", {"accountingID": "fixture-refund-receipt"}, role="Accounting")[0], 200)



    def test_technician_can_reconcile_own_dispatched_attempt_after_assignment_completion(self):
        self.assignment()
        attempt = self.reserve(role="Field Technician")
        self.assertEqual(self.action(attempt, "begin", role="Field Technician")[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE field_payment_assignments SET status='completed', collected_amount=100")
        self.seed_provider(attempt)
        self.seed_accounting(attempt)
        self.assertEqual(self.get(attempt, role="Field Technician")[0], 200)
        self.assertEqual(self.action(attempt, "confirm", {"providerID": "fixture-charge"}, role="Field Technician")[0], 200)
        self.assertEqual(self.action(attempt, "complete", {"accountingID": "fixture-accounting"}, role="Field Technician")[0], 200)
        self.assertEqual(self.request(payload=self.payload(), role="Field Technician")[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE field_payment_assignments SET status='cancelled'")
        self.assertEqual(self.get(attempt, role="Field Technician")[0], 403)

    def test_cancelled_unsent_reservation_does_not_pin_an_old_invoice_amount(self):
        self.invoice["Balance"] = 40
        attempt = self.reserve()
        self.assertEqual(self.action(attempt, "cancel")[0], 200)
        self.invoice["Balance"] = 100
        self.assertEqual(self.request(payload=self.payload(amountCents=10000))[0], 200)

    def test_dispatch_rechecks_invoice_balance_and_role_after_network_read(self):
        attempt = self.reserve()
        self.invoice["Balance"] = 10
        self.assertEqual(self.action(attempt, "begin")[0], 409)
        self.assertEqual(self.get(attempt)[1]["attempt"]["state"], "reserved")
        self.invoice["Balance"] = 100
        def demote(context, category, record_id, **kwargs):
            value = self.provider(context, category, record_id, **kwargs)
            with backend.db() as connection:
                connection.execute("UPDATE users SET role='Standard' WHERE email='admin@example.invalid'")
            return value
        with mock.patch.object(backend, "read_payment_provider_record", side_effect=demote):
            self.assertEqual(self.action(attempt, "begin")[0], 403)
        self.assertEqual(self.get(attempt, role="Accounting")[1]["attempt"]["state"], "reserved")

    def test_refund_rejects_unverified_source_and_cumulative_over_refund(self):
        source = self.payload(amountCents=10000)
        source["clientTransactionID"] = "ga-charge-" + source["id"]
        self.seed_provider(source, "fixture-original")
        self.seed_accounting(source, "fixture-original-accounting")
        payload = self.payload(kind="refund", amountCents=6000, sourcePaymentID=source["id"],
            sourceProviderID="fixture-original", sourceAccountingID="fixture-original-accounting")
        for changed in ({"currency": "EUR"}, {"status": "DECLINED"}, {"status": "PENDING"}):
            self.transactions["fixture-original"].update(changed)
            self.assertEqual(self.request(payload=payload)[0], 409)
            self.seed_provider(source, "fixture-original")
        status, body = self.request(payload=payload)
        self.assertEqual(status, 200, body)
        refund = body["attempt"]
        self.action(refund, "begin")
        self.seed_provider(refund, "fixture-refund")
        self.action(refund, "confirm", {"providerID": "fixture-refund"})
        self.seed_accounting(refund, "fixture-refund-accounting")
        self.action(refund, "complete", {"accountingID": "fixture-refund-accounting"})
        self.assertEqual(self.request(payload={**payload, "id": str(uuid.uuid4()), "amountCents": 5000})[0], 409)
        self.assertEqual(self.request(payload={**payload, "id": str(uuid.uuid4()), "amountCents": 4000})[0], 200)



    def test_native_uppercase_invoice_identity_matches_assignment_without_case_rewrite(self):
        self.assignment()
        with backend.db() as connection:
            connection.execute("UPDATE field_payment_assignments SET invoice_id=?", (self.invoice_id.upper(),))
        attempt = self.reserve(role="Field Technician", invoiceID=self.invoice_id.upper())
        self.assertEqual(self.action(attempt, "begin", role="Field Technician")[0], 200)

    def test_verified_collection_consumes_assignment_limit_before_queue_upload(self):
        self.assignment()
        with backend.db() as connection:
            connection.execute("UPDATE field_payment_assignments SET amount=50")
        attempt = self.reserve(role="Field Technician", amountCents=4000)
        self.action(attempt, "begin", role="Field Technician")
        self.seed_provider(attempt)
        self.action(attempt, "confirm", {"providerID": "fixture-charge"}, role="Field Technician")
        self.seed_accounting(attempt)
        self.action(attempt, "complete", {"accountingID": "fixture-accounting"}, role="Field Technician")
        self.assertEqual(self.request(payload=self.payload(amountCents=2000), role="Field Technician")[0], 403)
        self.assertEqual(self.request(payload=self.payload(amountCents=1000), role="Field Technician")[0], 200)


if __name__ == "__main__":
    unittest.main()
