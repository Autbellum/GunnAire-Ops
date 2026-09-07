from __future__ import annotations

import copy
import json
import sqlite3
import tempfile
import threading
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet
from Backend import gunnaire_backend as backend
from Backend import billing_publications as billing
from Backend import billing_provider
from Backend import payment_attempts


class BillingPublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.settings = mock.patch.multiple(backend, DATA_ROOT=root, DB_PATH=root / "billing.sqlite3", STORAGE_ROOT=root / "files",
            AUTH_MODE="google-id-token", PRIMARY_ADMIN_EMAIL="owner@example.invalid", QBO_TOKEN_ENCRYPTION_KEY=Fernet.generate_key().decode())
        self.settings.start()
        backend.initialize_database()
        self.customer_id, self.local_id, self.item_id = (str(uuid.uuid4()) for _ in range(3))
        self.remotes, self.writes, self.sessions = [], [], {}
        self.before_read, self.before_write, self.after_write = lambda: None, lambda: None, lambda remote: remote
        self.preflight = mock.Mock()
        with backend.db() as connection:
            self.company = connection.execute("SELECT company_id FROM company_identity").fetchone()[0]
            connection.execute("INSERT INTO qbo_connections VALUES (1,'realm','cipher','sandbox','client','grant','updated')")
            connection.execute("INSERT INTO customer_entity_mappings VALUES (?,'realm','sandbox',?,'C1')", (self.company, self.customer_id))
            connection.execute("INSERT INTO catalog_entity_mappings VALUES (?,'realm','sandbox',?,'I1')", (self.company, self.item_id))
            for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
                email = self.email(role)
                connection.execute("INSERT INTO users VALUES (?,?,1,?,?)", (email, role, backend.utc_now(), backend.utc_now()))
        for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
            token = backend.create_app_session(self.email(role), "google", "fixture")[0]
            with backend.db() as connection:
                self.sessions[role] = connection.execute("SELECT id FROM auth_sessions WHERE token_hash=?", (backend.app_session_token_hash(token),)).fetchone()[0]
        fixture = self
        class Provider:
            def __init__(self, context, authorize):
                self.authorize = authorize

            def documents(self, kind):
                values = copy.deepcopy(fixture.remotes)
                fixture.before_read()
                self.authorize()
                return values

            def read(self, kind, identifier):
                fixture.before_read()
                self.authorize()
                values = [value for value in fixture.remotes if value["Id"] == identifier]
                if len(values) != 1:
                    raise billing.failure("provider_unavailable", "Fixture unavailable.")
                return copy.deepcopy(values[0])

            def preflight(self, document):
                fixture.preflight(document)
                self.authorize()

            def write(self, kind, document, request_id, before_send):
                fixture.before_write()
                before_send()
                fixture.writes.append((kind, copy.deepcopy(document), request_id))
                remote = fixture.remote(document, Id=document.get("Id", "D1"), SyncToken=str(int(document.get("SyncToken", "-1")) + 1))
                fixture.remotes = [remote]
                return fixture.after_write(copy.deepcopy(remote))
        self.provider = Provider
        self.publisher = billing.BillingPublisher(backend.db, Provider, backend.encrypt_catalog_payload, backend.decrypt_catalog_payload, backend.record_audit_event)
        self.admin = self.sessions["Admin"]

    def tearDown(self):
        self.settings.stop()
        self.directory.cleanup()

    @staticmethod
    def email(role):
        return role.lower().replace(" ", ".") + "@example.invalid"

    def payload(self, **changes):
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox", "documentType": "Invoice",
            "localDocumentID": self.local_id, "localCustomerID": self.customer_id, "operation": "create",
            "document": {"CustomerRef": {"value": "C1", "name": "Taylor Customer"}, "TxnDate": "2026-09-07",
                "PrivateNote": "Repair saved from the original field draft.", "DueDate": "2026-10-07",
                "Line": [{"Amount": 189, "DetailType": "SalesItemLineDetail", "Description": "Sold repair labor",
                    "SalesItemLineDetail": {"ItemRef": {"value": "I1", "name": "Labor"}, "Qty": 1, "UnitPrice": 189, "TaxCodeRef": {"value": "NON"}}}]}, **changes}

    def estimate(self):
        payload = self.payload(documentType="Estimate")
        payload["document"].pop("DueDate")
        return payload

    def remote(self, document=None, **changes):
        document = document or billing.validated_request(self.payload())["document"]
        total = sum(line["Amount"] * (-1 if line["DetailType"] == "DiscountLineDetail" else 1) for line in document["Line"])
        return {**copy.deepcopy(document), "Id": "D1", "SyncToken": "0", "TotalAmt": total, "Balance": total,
                "TxnTaxDetail": {"TotalTax": 0}, "CurrencyRef": {"value": "USD"}, **changes}

    def publish(self, payload=None, role="Admin"):
        return self.publisher.publish(self.sessions[role], payload or self.payload())

    def row(self):
        with backend.db() as connection:
            return dict(connection.execute("SELECT * FROM billing_publications ORDER BY created_at DESC,id DESC LIMIT 1").fetchone())

    def expect(self, code, action):
        with self.assertRaises(billing.AttemptError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def update(self):
        self.publish()
        payload = self.payload(operation="update")
        payload["document"].update(Id="D1", SyncToken="0", sparse=True)
        payload["document"]["Line"][0]["Amount"] = 214
        payload["document"]["Line"][0]["SalesItemLineDetail"]["UnitPrice"] = 214
        return payload

    def payment_coordinator(self):
        return payment_attempts.PaymentAttemptJournal(backend.db, lambda context, identifier: self.remote(),
            mock.Mock(), mock.Mock(), backend.record_audit_event)

    def payment_payload(self, **changes):
        return {"id": str(uuid.uuid4()), "companyID": self.company, "realmID": "realm", "environment": "sandbox",
            "invoiceID": self.local_id, "invoiceQuickBooksID": "D1", "customerQuickBooksID": "C1",
            "amountCents": 100, "rail": "card", "kind": "charge", **changes}

    def test_create_once_with_stable_identity_date_and_explicit_no_send_flags(self):
        first, replay = self.publish(), self.publish()
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(first["publication"]["id"], replay["publication"]["id"])
        self.assertEqual(self.writes[0][2], "ga-invoice-" + self.local_id)
        self.assertLessEqual(len(self.writes[0][2]), 50)
        sent = self.writes[0][1]
        for flag in ("AllowOnlineACHPayment", "AllowOnlineCreditCardPayment", "AllowOnlineAffirmPayment", "AllowOnlinePayPalPayment"):
            self.assertIs(sent[flag], False)
        self.assertEqual(sent["EmailStatus"], "NotSet")
        self.assertEqual(sent["TxnDate"], "2026-09-07")
        self.assertEqual(sent["Line"][0]["Amount"], 189)

    def test_estimate_creation_preserves_sold_values_and_does_not_set_invoice_payment_flags(self):
        self.publish(self.estimate(), role="Dispatcher")
        self.assertEqual(self.writes[0][0], "Estimate")
        self.assertEqual(self.writes[0][2], "ga-estimate-" + self.local_id)
        self.assertFalse(any(key.startswith("AllowOnline") for key in self.writes[0][1]))

    def test_office_permissions_match_document_type_not_a_primary_email_bypass(self):
        for role in ("Dispatcher", "Standard", "Field Technician"):
            self.expect("review_required", lambda: self.publish(role=role))
        self.expect("review_required", lambda: self.publish(self.estimate(), role="Accounting"))
        self.publish(role="Accounting")
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard' WHERE role='Admin'")
        with mock.patch.object(backend, "PRIMARY_ADMIN_EMAIL", self.email("Admin")):
            self.expect("review_required", self.publish)

    def test_technician_cannot_claim_an_assignment_or_approve_own_document(self):
        for extra in ({"assignedToJob": True}, {"role": "Admin"}, {"approvalID": str(uuid.uuid4())}):
            self.expect("invalid_request", lambda: self.publish(self.payload(**extra), role="Field Technician"))
        self.expect("review_required", lambda: self.publisher.approve_draft(self.sessions["Field Technician"], self.payload(), self.email("Field Technician")))
        self.assertFalse(self.writes)

    def test_exact_office_review_allows_field_draft_without_repricing(self):
        self.publisher.approve_draft(self.admin, self.payload(), self.email("Field Technician"))
        result = self.publish(role="Field Technician")
        self.assertEqual(result["document"]["Line"][0]["Amount"], 189)
        self.assertEqual(len(self.writes), 1)

    def test_changed_field_price_customer_date_or_notes_needs_new_review(self):
        self.publisher.approve_draft(self.admin, self.payload(), self.email("Field Technician"))
        for key, value in (("PrivateNote", "Changed"), ("DueDate", "2026-11-07"), ("CustomerRef", {"value": "other"})):
            payload = self.payload()
            payload["document"][key] = value
            self.expect("review_required", lambda: self.publish(payload, role="Field Technician"))
        payload = self.payload()
        payload["document"]["Line"][0].update(Amount=190)
        payload["document"]["Line"][0]["SalesItemLineDetail"]["UnitPrice"] = 190
        self.expect("review_required", lambda: self.publish(payload, role="Field Technician"))
        self.assertFalse(self.writes)

    def test_approving_a_new_revision_revokes_the_technicians_old_draft_permission(self):
        self.publisher.approve_draft(self.admin, self.payload(), self.email("Field Technician"))
        revised = self.payload()
        revised["document"]["PrivateNote"] = "The latest office-reviewed revision"
        self.publisher.approve_draft(self.admin, revised, self.email("Field Technician"))
        self.expect("review_required", lambda: self.publish(role="Field Technician"))
        self.publish(revised, role="Field Technician")
        self.assertEqual(len(self.writes), 1)

    def test_revoked_expired_reconnected_or_demoted_office_approval_cannot_send(self):
        identifier = self.publisher.approve_draft(self.admin, self.payload(), self.email("Field Technician"))
        self.publisher.revoke_draft(self.admin, identifier)
        self.expect("review_required", lambda: self.publish(role="Field Technician"))
        for sql in ("UPDATE billing_draft_grants SET expires_at='2000-01-01T00:00:00+00:00'",
                    "UPDATE qbo_connections SET authorized_at='replacement'", "UPDATE users SET is_active=0 WHERE role='Admin'"):
            self.publisher.approve_draft(self.admin, self.payload(), self.email("Field Technician"))
            with backend.db() as connection:
                connection.execute(sql)
            self.expect("review_required", lambda: self.publish(role="Field Technician"))
        self.assertFalse(self.writes)

    def test_missing_expired_future_and_revoked_sessions_fail_before_provider_access(self):
        self.expect("access_denied", lambda: self.publisher.publish("missing", self.payload()))
        with backend.db() as connection:
            original = dict(connection.execute("SELECT * FROM auth_sessions WHERE id=?", (self.admin,)).fetchone())
        for field, value in (("created_at", "2999-01-01T00:00:00+00:00"), ("expires_at", "2000-01-01T00:00:00+00:00"), ("revoked_at", "now")):
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET created_at=?,expires_at=?,revoked_at=NULL WHERE id=?", (original["created_at"], original["expires_at"], self.admin))
                connection.execute("UPDATE auth_sessions SET " + field + "=? WHERE id=?", (value, self.admin))
            self.expect("access_denied", self.publish)
        self.assertFalse(self.writes)

    def test_exact_company_realm_environment_and_mappings_are_required(self):
        for key, value, error in (("companyID", str(uuid.uuid4()), "company_changed"), ("realmID", "other", "provider_changed"),
                                  ("environment", "production", "provider_changed"), ("localCustomerID", str(uuid.uuid4()), "customer_review")):
            self.expect(error, lambda: self.publish(self.payload(**{key: value})))
        with backend.db() as connection:
            connection.execute("DELETE FROM catalog_entity_mappings")
        self.expect("item_review", self.publish)
        self.assertFalse(self.writes)

    def test_payload_is_encrypted_and_public_status_omits_private_contact_or_authorization_details(self):
        result = self.publish()
        self.assertNotIn("Repair saved", self.row()["payload_ciphertext"])
        self.assertEqual(json.loads(backend.decrypt_catalog_payload(self.row()["payload_ciphertext"]))["document"]["Line"][0]["Amount"], 189)
        for secret in ("@", "Repair saved", "payload_hash", "grant_fingerprint", "request_id", "actor_email", "ciphertext"):
            self.assertNotIn(secret, json.dumps(result["publication"]))

    def test_invalid_financial_and_automatic_send_fields_never_reach_provider(self):
        for key, value in (("TotalAmt", 100), ("Balance", 100), ("EmailStatus", "NeedToSend"), ("AllowOnlineACHPayment", True),
                           ("Deposit", 100), ("PaymentRef", {"value": "1"}), ("url", "https://example.invalid"), ("Id", "D1"),
                           ("PrivateNote", "GunnAire Invoice ID: " + self.local_id), ("TxnDate", "2026-02-31"),
                           ("CurrencyRef", {"value": "CAD"}), ("GlobalTaxCalculation", "TaxInclusive")):
            payload = self.payload()
            payload["document"][key] = value
            with self.subTest(key=key), self.assertRaises(billing.AttemptError):
                self.publish(payload)
        self.assertFalse(self.writes)

    def test_nan_infinity_bool_negative_excessive_and_mismatched_line_amounts_are_rejected(self):
        for amount in (float("nan"), float("inf"), True, -1, 1e15, 189.001, 190, "189"):
            payload = self.payload()
            payload["document"]["Line"][0]["Amount"] = amount
            with self.subTest(amount=amount), self.assertRaises(billing.AttemptError):
                self.publish(payload)
        for quantity in (0, -1, 1e12, True, .000001):
            payload = self.payload()
            payload["document"]["Line"][0]["SalesItemLineDetail"]["Qty"] = quantity
            with self.assertRaises(billing.AttemptError):
                self.publish(payload)
        self.assertFalse(self.writes)

    def test_fixed_and_percentage_discount_keep_the_reviewed_sold_total(self):
        payload = self.payload()
        payload["document"].update(ApplyTaxAfterDiscount=True)
        payload["document"]["Line"].append({"Amount": 18.9, "DetailType": "DiscountLineDetail", "DiscountLineDetail": {"PercentBased": True, "DiscountPercent": 10}})
        result = self.publish(payload)
        self.assertEqual(result["document"]["TotalAmt"], 170.1)
        invalid = copy.deepcopy(payload)
        invalid["document"]["Line"][-1]["Amount"] = 20
        self.expect("invalid_lines", lambda: self.publish(invalid))

    def test_unknown_create_survives_restart_and_recovers_without_resending(self):
        self.after_write = mock.Mock(side_effect=TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish()
        self.assertEqual(self.row()["state"], "unknown")
        restarted = billing.BillingPublisher(backend.db, self.provider, backend.encrypt_catalog_payload, backend.decrypt_catalog_payload, backend.record_audit_event)
        result = restarted.run(self.admin, self.row()["id"])
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)

    def test_unknown_absence_or_local_identity_without_original_attempt_cannot_resend(self):
        self.after_write = mock.Mock(side_effect=TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish()
        self.remotes[0]["PrivateNote"] = billing.marker(self.row())
        self.expect("provider_unconfirmed", self.publish)
        self.remotes = []
        self.expect("provider_unconfirmed", self.publish)
        self.expect("publication_pending", lambda: self.publisher.cancel(self.admin, self.row()["id"]))
        self.assertEqual(len(self.writes), 1)

    def test_unsent_recovery_never_dispatches_and_cancel_preserves_all_other_data(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.expect("provider_unconfirmed", lambda: self.publisher.run(self.admin, row["id"]))
        self.publisher.cancel(self.admin, row["id"])
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM customer_entity_mappings").fetchone()[0], 1)
        self.assertFalse(self.writes)
        self.publish()
        self.assertEqual(len(self.writes), 1)

    def test_legacy_document_can_link_once_but_duplicate_identity_requires_review(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.remotes = [self.remote(self.publisher.payload(row))]
        self.remotes[0]["PrivateNote"] = billing.marker(row)
        self.publish()
        self.publish()
        self.assertFalse(self.writes)
        self.remotes.append({**self.remotes[0], "Id": "D2"})
        # Confirmed replays read the mapped provider ID, not an arbitrary list.
        self.assertEqual(self.publish()["document"]["Id"], "D1")

    def test_ambiguous_first_census_does_not_adopt_either_document(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.remotes = [self.remote(self.publisher.payload(row)), self.remote(self.publisher.payload(row), Id="D2")]
        self.expect("identity_conflict", self.publish)
        self.assertFalse(self.writes)

    def test_changed_or_deleted_remote_never_creates_a_replacement(self):
        self.publish()
        self.remotes[0]["Line"][0]["Amount"] = 2
        with self.assertRaises(billing.AttemptError):
            self.publish()
        self.remotes = []
        self.expect("provider_unavailable", self.publish)
        self.assertEqual(len(self.writes), 1)

    def test_malformed_customer_lines_tax_total_dates_and_currency_retain_unknown(self):
        def malformed(remote):
            remote["TotalAmt"] = 999
            return remote
        self.after_write = malformed
        self.expect("provider_unconfirmed", self.publish)
        self.assertEqual(self.row()["state"], "unknown")
        correct = copy.deepcopy(self.remotes[0])
        for key, value in (("CustomerRef", None), ("Line", None), ("TxnTaxDetail", None), ("CurrencyRef", None),
                           ("TxnDate", "2026-01-01"), ("Balance", 1000), ("TotalAmt", True)):
            remote = {**copy.deepcopy(correct), key: value}
            with self.subTest(key=key), self.assertRaises(billing.AttemptError):
                self.publisher.confirm(self.admin, self.row()["id"], remote, original_attempt=True)
        self.assertEqual(len(self.writes), 1)

    def test_exact_version_unpaid_update_is_dispatched_once_and_preserves_online_payment_settings(self):
        payload = self.update()
        result = self.publish(payload)
        self.assertEqual(result["document"]["TotalAmt"], 214)
        self.publish(payload)
        self.assertEqual(len(self.writes), 2)
        self.assertTrue(self.writes[1][1]["sparse"])
        self.assertFalse(any(key.startswith("AllowOnline") for key in self.writes[1][1]))
        self.assertNotEqual(self.writes[1][2], self.writes[0][2])

    def test_paid_or_stale_invoice_is_not_updated(self):
        payload = self.update()
        self.remotes[0]["SyncToken"] = "8"
        self.expect("version_changed", lambda: self.publish(payload))
        self.remotes[0]["SyncToken"] = "0"
        self.remotes[0]["Balance"] = 100
        self.expect("payment_review", lambda: self.publish(payload))
        self.assertEqual(len(self.writes), 1)

    def test_update_recovery_requires_update_marker_not_just_matching_new_values(self):
        payload = self.update()
        self.after_write = mock.Mock(side_effect=TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish(payload)
        self.remotes[0]["PrivateNote"] = billing.marker(self.row())
        self.expect("provider_unconfirmed", lambda: self.publish(payload))
        self.assertEqual(len(self.writes), 2)

    def test_role_or_original_grant_loss_during_read_or_immediately_before_send_stops_dispatch(self):
        def revoke():
            with backend.db() as connection:
                connection.execute("UPDATE users SET is_active=0 WHERE role='Admin'")
        self.before_read = revoke
        self.expect("access_denied", self.publish)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=1")
        self.before_read = lambda: None
        def reconnect():
            with backend.db() as connection:
                connection.execute("UPDATE qbo_connections SET authorized_at='replacement'")
        self.before_write = reconnect
        self.expect("grant_changed", self.publish)
        self.assertFalse(self.writes)
        self.assertEqual(self.row()["state"], "reserved")

    def test_approval_revocation_immediately_before_technician_send_is_rechecked(self):
        grant = self.publisher.approve_draft(self.admin, self.payload(), self.email("Field Technician"))
        self.before_write = lambda: self.publisher.revoke_draft(self.admin, grant)
        self.expect("review_required", lambda: self.publish(role="Field Technician"))
        self.assertFalse(self.writes)

    def test_role_loss_after_acceptance_keeps_uncertain_attempt_for_office_recovery(self):
        def revoke(remote):
            with backend.db() as connection:
                connection.execute("UPDATE users SET is_active=0 WHERE role='Admin'")
            return remote
        self.after_write = revoke
        self.expect("access_denied", self.publish)
        self.assertEqual(self.row()["state"], "unknown")
        result = self.publisher.run(self.sessions["Accounting"], self.row()["id"])
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)

    def test_audit_failure_rolls_back_dispatch_and_confirmation_mapping(self):
        original = self.publisher.audit
        def fail_dispatch(actor, action, *args, **kwargs):
            if action == "dispatch":
                raise sqlite3.OperationalError("fixture audit failure")
            return original(actor, action, *args, **kwargs)
        self.publisher.audit = fail_dispatch
        with self.assertRaises(sqlite3.OperationalError):
            self.publish()
        self.assertFalse(self.writes)
        self.assertEqual(self.row()["state"], "reserved")
        def fail_confirm(actor, action, *args, **kwargs):
            if action == "confirm":
                raise sqlite3.OperationalError("fixture audit failure")
            return original(actor, action, *args, **kwargs)
        self.publisher.audit = fail_confirm
        with self.assertRaises(sqlite3.OperationalError):
            self.publish()
        self.assertEqual(self.row()["state"], "unknown")
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM billing_entity_mappings").fetchone()[0], 0)

    def test_corrupted_saved_payload_never_dispatches(self):
        row = self.publisher.reserve(self.admin, self.payload())
        with backend.db() as connection:
            connection.execute("UPDATE billing_publications SET payload_ciphertext='invalid' WHERE id=?", (row["id"],))
        self.expect("storage_unavailable", self.publish)
        self.assertFalse(self.writes)

    def test_two_devices_racing_same_document_use_one_provider_dispatch(self):
        barrier = threading.Barrier(2)
        self.before_write = lambda: barrier.wait(timeout=5)
        def attempt():
            try:
                return self.publish()
            except billing.AttemptError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: attempt(), range(2)))
        self.assertEqual(len(self.writes), 1)
        self.assertTrue(any(isinstance(value, dict) for value in results))

    def test_cancel_and_dispatch_race_never_sends_cancelled_intent(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.before_write = lambda: self.publisher.cancel(self.admin, row["id"])
        self.expect("publication_pending", self.publish)
        self.assertFalse(self.writes)
        self.assertEqual(self.row()["state"], "cancelled")

    def test_invoice_publication_and_payment_reservation_exclude_each_other(self):
        payload = self.update()
        row = self.publisher.reserve(self.admin, payload)
        coordinator = self.payment_coordinator()
        self.expect("billing_needs_review", lambda: coordinator.reserve(self.admin, self.payment_payload()))
        self.publisher.cancel(self.admin, row["id"])
        coordinator.reserve(self.admin, self.payment_payload())
        self.expect("payment_review", lambda: self.publish(payload))

    def test_duplicate_native_uuid_cannot_collect_during_same_provider_invoice_update(self):
        payload = self.update()
        self.publisher.reserve(self.admin, payload)
        self.expect("billing_needs_review", lambda: self.payment_coordinator().reserve(self.admin, self.payment_payload(invoiceID=str(uuid.uuid4()))))

    def test_payment_begin_rechecks_billing_boundary_and_cancel_remains_available(self):
        self.publish()
        coordinator = self.payment_coordinator()
        payment = coordinator.reserve(self.admin, self.payment_payload())
        # Simulates retained data imported from another/older process. Normal
        # reservation paths already exclude this conflict in both directions.
        with backend.db() as connection:
            connection.execute("UPDATE billing_publications SET state='unknown'")
        self.expect("billing_needs_review", lambda: coordinator.begin(self.admin, payment["id"]))
        self.assertEqual(coordinator.cancel(self.admin, payment["id"])["state"], "cancelled")

    def test_changed_proposals_on_two_devices_do_not_reuse_an_immutable_intent(self):
        self.publisher.reserve(self.admin, self.payload())
        changed = self.payload()
        changed["document"]["PrivateNote"] = "A different saved revision"
        self.expect("publication_pending", lambda: self.publish(changed))
        self.assertFalse(self.writes)

    def test_invoice_update_mapping_is_rechecked_immediately_before_dispatch(self):
        payload = self.update()
        def change_mapping():
            with backend.db() as connection:
                connection.execute("UPDATE billing_entity_mappings SET provider_id='D2'")
        self.before_write = change_mapping
        self.expect("identity_conflict", lambda: self.publish(payload))
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.row()["state"], "reserved")

    def test_customer_or_catalog_mapping_loss_after_preflight_stops_dispatch(self):
        def remove_mapping():
            with backend.db() as connection:
                connection.execute("DELETE FROM customer_entity_mappings")
        self.before_write = remove_mapping
        self.expect("customer_review", self.publish)
        self.assertFalse(self.writes)

    def test_different_local_document_cannot_take_an_existing_provider_mapping(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.remotes = [self.remote(self.publisher.payload(row))]
        with backend.db() as connection:
            connection.execute("INSERT INTO billing_entity_mappings VALUES (?,'realm','sandbox','Invoice',?,?,'D1')",
                               (self.company, str(uuid.uuid4()), self.customer_id))
        self.expect("identity_conflict", self.publish)
        self.assertFalse(self.writes)

    def test_public_response_omits_provider_tax_identifiers_metadata_and_line_accounts(self):
        def extra_fields(remote):
            remote.update(TaxIdentifier="private-tax-id", MetaData={"internal": "private-metadata"}, BillAddr={"Line1": "private-address"})
            remote["Line"][0]["SalesItemLineDetail"]["AccountRef"] = {"value": "private-account"}
            return remote
        self.after_write = extra_fields
        result = self.publish()
        for private in ("private-tax-id", "private-metadata", "private-address", "private-account"):
            self.assertNotIn(private, json.dumps(result))

    def test_duplicate_provider_line_identity_or_conflicting_subtotal_requires_review(self):
        row = self.publisher.reserve(self.admin, self.payload())
        document = self.publisher.payload(row)
        remote = self.remote(document)
        remote["Line"][0]["Id"] = "1"
        remote["Line"].append({"Id": "1", "Amount": 189, "DetailType": "SubTotalLineDetail"})
        self.expect("provider_unconfirmed", lambda: self.publisher.confirm(self.admin, row["id"], remote, original_attempt=True))
        remote["Line"][-1]["Id"] = "2"
        remote["Line"][-1]["Amount"] = 200
        self.expect("provider_unconfirmed", lambda: self.publisher.confirm(self.admin, row["id"], remote, original_attempt=True))
        remote["Line"][-1]["Amount"] = 189
        self.publisher.confirm(self.admin, row["id"], remote, original_attempt=True)

    def test_conflicting_document_lineage_cannot_confirm_a_customer_invoice(self):
        row = self.publisher.reserve(self.admin, self.payload())
        remote = self.remote(self.publisher.payload(row))
        remote["PrivateNote"] += "\nGunnAire Invoice ID: " + str(uuid.uuid4()).upper()
        self.expect("identity_conflict", lambda: self.publisher.confirm(self.admin, row["id"], remote, original_attempt=True))

    def test_returned_billing_email_must_match_the_reviewed_recipient(self):
        payload = self.payload()
        payload["document"]["BillEmail"] = {"Address": "taylor@example.invalid"}
        row = self.publisher.reserve(self.admin, payload)
        for email in ({"Address": "different@example.invalid"}, {"Address": None}, None):
            remote = self.remote(self.publisher.payload(row), BillEmail=email)
            self.expect("provider_unconfirmed", lambda: self.publisher.confirm(self.admin, row["id"], remote, original_attempt=True))

    def test_document_and_payment_race_reserves_exactly_one_side(self):
        payload = self.update()
        barrier = threading.Barrier(2)
        def reserve_billing():
            barrier.wait(timeout=5)
            try:
                return self.publisher.reserve(self.admin, payload)
            except billing.AttemptError as error:
                return error.code
        def reserve_payment():
            barrier.wait(timeout=5)
            try:
                return self.payment_coordinator().reserve(self.admin, self.payment_payload())
            except billing.AttemptError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            left, right = pool.submit(reserve_billing), pool.submit(reserve_payment)
            results = [left.result(), right.result()]
        self.assertEqual(sum(isinstance(value, dict) for value in results), 1)
        self.assertTrue(any(value in ("billing_needs_review", "payment_review") for value in results if isinstance(value, str)))

    def test_uncertain_attempt_survives_database_backup_restore_without_resend(self):
        self.after_write = mock.Mock(side_effect=TimeoutError())
        with self.assertRaises(TimeoutError):
            self.publish()
        identifier = self.row()["id"]
        restored_path = Path(self.directory.name) / "restored.sqlite3"
        with backend.db() as source, sqlite3.connect(restored_path) as destination:
            source.backup(destination)
        with mock.patch.object(backend, "DB_PATH", restored_path):
            backend.initialize_database()
            result = self.publisher.run(self.admin, identifier)
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)

    def test_schema_initialization_does_not_commit_the_callers_transaction(self):
        with backend.db() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("UPDATE users SET is_active=0 WHERE role='Admin'")
            billing.initialize_schema(connection)
            connection.rollback()
        self.publish()

    def test_shared_engine_and_real_provider_adapter_complete_one_fixture_only_round_trip(self):
        requests, remote_records = [], []
        def transport(request):
            from urllib.parse import urlsplit, parse_qs
            requests.append(request)
            path, query = urlsplit(request.full_url).path, parse_qs(urlsplit(request.full_url).query)
            if path.endswith("/query"):
                if "COUNT(*)" in query["query"][0]:
                    return {"QueryResponse": {"totalCount": len(remote_records)}}
                return {"QueryResponse": {"Invoice": copy.deepcopy(remote_records), "startPosition": 1, "maxResults": len(remote_records)}}
            if path.endswith("/preferences"):
                return {"Preferences": {"CurrencyPrefs": {"HomeCurrency": {"value": "USD"}, "MultiCurrencyEnabled": False}}}
            if path.endswith("/companyinfo/realm"):
                return {"CompanyInfo": {"Id": "1", "Country": "USA"}}
            if path.endswith("/customer/C1"):
                return {"Customer": {"Id": "C1", "Active": True}}
            if path.endswith("/item/I1"):
                return {"Item": {"Id": "I1", "Active": True, "Type": "Service", "UnitPrice": 999}}
            if request.get_method() == "POST":
                self.assertEqual(path, "/v3/company/realm/invoice")
                remote = self.remote(json.loads(request.data))
                remote["Line"][0]["Id"] = "1"
                remote_records.append(remote)
                return {"Invoice": copy.deepcopy(remote)}
            if path.endswith("/invoice/D1"):
                return {"Invoice": copy.deepcopy(remote_records[0])}
            self.fail("Unexpected fixture provider request")
        bearer = mock.Mock(return_value="fixture-bearer")
        self.publisher.provider_factory = lambda context, authorize: billing_provider.BillingQBOProvider(context, authorize, bearer, transport)
        original, replay = self.publish(), self.publish()
        self.assertEqual(original["publication"]["id"], replay["publication"]["id"])
        self.assertEqual(original["document"]["TotalAmt"], 189)
        self.assertEqual(sum(request.get_method() == "POST" for request in requests), 1)


if __name__ == "__main__":
    unittest.main()
