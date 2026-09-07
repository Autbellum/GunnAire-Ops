from __future__ import annotations

import copy
import json
import sqlite3
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from unittest import mock

from Backend import gunnaire_backend as backend, qbo_link_adoption as adoption, billing_provider
from Backend.test_billing_publications import BillingFixture


class LinkAdoptionTests(BillingFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.estimate_id, self.job_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.reads = []
        base = self.provider
        fixture = self
        class Provider(base):
            def read(self, kind, identifier):
                fixture.reads.append((kind, identifier))
                return super().read(kind, identifier)
        self.provider = Provider
        self.adopter = adoption.LinkAdopter(backend.db, Provider, backend.encrypt_catalog_payload, backend.decrypt_catalog_payload, backend.record_audit_event)
        self.remotes = [
            {"Id": "C1", "SyncToken": "0", "DisplayName": "Taylor Customer", "Active": True,
             "PrimaryEmailAddr": {"Address": "taylor@example.invalid"}, "TaxIdentifier": "do-not-retain"},
            {"Id": "I1", "SyncToken": "0", "Name": "Labor", "Active": True, "Type": "Service", "UnitPrice": 189, "Taxable": False},
            self.remote(PrivateNote="Imported invoice", DocNumber="INV-104"),
            self.remote(Id="E1", PrivateNote="Imported estimate", DocNumber="EST-90"),
        ]
        with backend.db() as connection:
            connection.execute("DELETE FROM customer_entity_mappings")
            connection.execute("DELETE FROM catalog_entity_mappings")

    def query(self, **changes):
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox", **changes}

    def review_request(self, **changes):
        epoch = self.adopter.lookup(self.admin, self.query())["connectionRevision"]
        return {**self.query(), "operationID": str(uuid.uuid4()), "connectionRevision": epoch, "links": [
            {"kind": "Customer", "localID": self.customer_id, "providerID": "C1", "localName": "Taylor Customer"},
            {"kind": "Item", "localID": self.item_id, "providerID": "I1", "localName": "Sold repair labor"},
            {"kind": "Invoice", "localID": self.local_id, "providerID": "D1", "localName": "Service invoice", "localCustomerID": self.customer_id, "serviceCallID": self.job_id},
            {"kind": "Estimate", "localID": self.estimate_id, "providerID": "E1", "localName": "Replacement proposal", "localCustomerID": self.customer_id},
        ], **changes}

    def preview(self, payload=None):
        return self.adopter.preview(self.admin, payload or self.review_request())

    def confirm(self, review):
        return self.adopter.decide(self.admin, review["id"], review["revision"], confirm=True)

    def counts(self):
        with backend.db() as connection:
            return tuple(connection.execute("SELECT COUNT(*) FROM " + table).fetchone()[0] for table in
                         ("customer_entity_mappings", "catalog_entity_mappings", "billing_entity_mappings", "billing_job_documents"))

    def test_preview_is_exact_read_only_and_retains_private_evidence_encrypted(self):
        review = self.preview()
        self.assertEqual(self.counts(), (0, 0, 0, 0))
        self.assertEqual(set(self.reads), {("Customer", "C1"), ("Item", "I1"), ("Invoice", "D1"), ("Estimate", "E1")})
        self.assertEqual(review["state"], "review")
        self.assertNotIn("do-not-retain", json.dumps(review))
        self.assertNotIn("contentHash", json.dumps(review))
        with backend.db() as connection:
            row = connection.execute("SELECT * FROM qbo_link_reviews").fetchone()
            self.assertNotIn("Taylor Customer", str(tuple(row)))
            self.assertNotIn("Imported invoice", backend.decrypt_catalog_payload(row["payload_ciphertext"]))
        self.assertFalse(self.writes)

    def test_explicit_confirmation_adopts_all_four_types_atomically_and_replays_without_reads(self):
        review = self.preview()
        result = self.confirm(review)
        self.assertEqual(result["state"], "confirmed")
        self.assertEqual(self.counts(), (1, 1, 2, 1))
        reads = len(self.reads)
        self.assertEqual(self.confirm(review), result)
        self.assertEqual(len(self.reads), reads)
        self.assertFalse(self.writes)

    def test_lost_preview_and_confirmation_recover_by_original_operation_and_id(self):
        payload = self.review_request()
        review = self.preview(payload)
        self.assertEqual(self.preview(payload), review)
        self.assertEqual(len(self.reads), 4)
        result = self.adopter.lookup(self.admin, self.query(operationID=payload["operationID"]))["review"]
        self.assertEqual(result, review)
        self.confirm(review)
        self.assertEqual(self.adopter.read(self.admin, review["id"])["state"], "confirmed")
        self.assertEqual(self.adopter.lookup(self.admin, self.query(operationID=payload["operationID"]))["review"]["state"], "confirmed")

    def test_changed_operation_payload_cannot_replace_the_saved_review(self):
        payload = self.review_request()
        self.preview(payload)
        payload["links"][0]["localName"] = "Other local customer"
        self.expect("review_changed", lambda: self.preview(payload))

    def test_cancel_never_adopts_and_conflicting_decisions_fail(self):
        review = self.preview()
        cancelled = self.adopter.decide(self.admin, review["id"], review["revision"], confirm=False)
        self.assertEqual(cancelled["state"], "cancelled")
        self.assertEqual(self.adopter.decide(self.admin, review["id"], review["revision"], confirm=False), cancelled)
        self.expect("review_changed", lambda: self.confirm(review))
        self.assertEqual(self.counts(), (0, 0, 0, 0))
        self.assertEqual(len(self.reads), 4)

    def test_review_revision_is_required_even_for_confirmed_replay(self):
        review = self.preview()
        self.expect("review_changed", lambda: self.confirm({**review, "revision": "0" * 64}))
        self.confirm(review)
        self.expect("review_changed", lambda: self.confirm({**review, "revision": "wrong"}))

    def test_nonadministrators_and_revoked_sessions_cannot_read_or_confirm(self):
        review, payload = self.preview(), self.review_request()
        for role in ("Accounting", "Dispatcher", "Field Technician", "Standard"):
            for action in (lambda: self.adopter.preview(self.sessions[role], payload),
                           lambda: self.adopter.read(self.sessions[role], review["id"]),
                           lambda: self.adopter.decide(self.sessions[role], review["id"], review["revision"], confirm=True)):
                self.expect("administrator_required", action)
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE id=?", (backend.utc_now(), self.admin))
        self.expect("access_denied", lambda: self.confirm(review))

    def test_company_realm_environment_and_reconnection_are_revalidated(self):
        for change, code in (({"companyID": str(uuid.uuid4())}, "company_changed"), ({"realmID": "other"}, "provider_changed"), ({"environment": "production"}, "provider_changed")):
            self.expect(code, lambda: self.preview(self.review_request(**change)))
        review = self.preview()
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='new-authorization'")
        self.expect("grant_changed", lambda: self.confirm(review))
        self.assertEqual(self.adopter.read(self.admin, review["id"]), review)
        self.assertEqual(self.counts(), (0, 0, 0, 0))

    def test_reconnected_admin_can_recover_and_cancel_but_cannot_adopt_stale_review(self):
        payload = self.review_request()
        review = self.preview(payload)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='reconnected'")
        result = self.adopter.lookup(self.admin, self.query(operationID=payload["operationID"]))
        self.assertNotEqual(result["connectionRevision"], payload["connectionRevision"])
        self.assertEqual(result["review"], review)
        self.expect("grant_changed", lambda: self.confirm(review))
        self.expect("grant_changed", lambda: self.preview(payload))
        reads = len(self.reads)
        cancelled = self.adopter.decide(self.admin, review["id"], review["revision"], confirm=False)
        self.assertEqual(cancelled["state"], "cancelled")
        self.assertEqual(len(self.reads), reads)
        self.assertEqual(self.counts(), (0, 0, 0, 0))
        self.assertEqual(self.preview()["state"], "review")

    def test_historical_read_and_cancel_still_require_exact_scope_and_current_admin(self):
        review = self.preview()
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET realm_id='different',authorized_at='reconnected'")
        for action in (lambda: self.adopter.read(self.admin, review["id"]),
                       lambda: self.adopter.decide(self.admin, review["id"], review["revision"], confirm=False)):
            self.expect("provider_changed", action)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET realm_id='realm'")
            connection.execute("UPDATE users SET role='Standard' WHERE role='Admin'")
        self.expect("administrator_required", lambda: self.adopter.decide(self.admin, review["id"], review["revision"], confirm=False))

    def test_reconnection_during_preview_prevents_late_old_operation_from_being_saved(self):
        payload = self.review_request()
        def reconnect():
            with backend.db() as connection:
                connection.execute("UPDATE qbo_connections SET authorized_at='reconnected'")
        self.before_read = reconnect
        self.expect("grant_changed", lambda: self.preview(payload))
        self.assertIsNone(self.adopter.lookup(self.admin, self.query(operationID=payload["operationID"]))["review"])
        self.assertEqual(self.counts(), (0, 0, 0, 0))

    def test_role_change_during_provider_read_prevents_adoption(self):
        review = self.preview()
        def revoke():
            with backend.db() as connection:
                connection.execute("UPDATE users SET role='Standard' WHERE role='Admin'")
        self.before_read = revoke
        self.expect("administrator_required", lambda: self.confirm(review))
        self.assertEqual(self.counts(), (0, 0, 0, 0))

    def test_changed_version_price_or_invoice_balance_requires_new_review(self):
        for index, field, replacement in ((0, "SyncToken", "1"), (1, "UnitPrice", 200), (2, "Balance", 100)):
            review = self.preview()
            original = self.remotes[index][field]
            self.remotes[index][field] = replacement
            self.expect("provider_changed", lambda: self.confirm(review))
            self.remotes[index][field] = original
        self.assertEqual(self.counts(), (0, 0, 0, 0))

    def test_price_change_never_reprices_saved_lines(self):
        review = self.preview()
        before = copy.deepcopy(self.remotes)
        self.confirm(review)
        self.assertEqual(self.remotes, before)
        self.assertEqual(self.remotes[1]["UnitPrice"], 189)

    def test_wrong_customer_and_foreign_document_or_customer_lineage_are_rejected(self):
        self.remotes[2]["CustomerRef"] = {"value": "OTHER"}
        self.expect("customer_conflict", self.preview)
        self.remotes[2]["CustomerRef"] = {"value": "C1"}
        self.remotes[2]["PrivateNote"] = "GunnAire Invoice ID: " + str(uuid.uuid4()).upper()
        self.expect("identity_conflict", self.preview)
        self.remotes[2]["PrivateNote"] = "Imported invoice"
        self.remotes[0]["Notes"] = "GunnAireCustomerID:" + str(uuid.uuid4())
        self.expect("identity_conflict", self.preview)

    def test_existing_local_or_provider_mapping_cannot_be_replaced(self):
        review = self.preview()
        with backend.db() as connection:
            connection.execute("INSERT INTO catalog_entity_mappings VALUES (?,'realm','sandbox',?,'I1')", (self.company, str(uuid.uuid4())))
        self.expect("identity_conflict", lambda: self.confirm(review))
        self.assertEqual(self.counts(), (0, 1, 0, 0))

    def test_pending_publication_cannot_be_bypassed_by_link_adoption(self):
        review = self.preview()
        with backend.db() as connection:
            connection.execute("INSERT INTO customer_entity_mappings VALUES (?,'realm','sandbox',?,'C1')", (self.company, self.customer_id))
            connection.execute("INSERT INTO catalog_entity_mappings VALUES (?,'realm','sandbox',?,'I1')", (self.company, self.item_id))
        self.publisher.reserve(self.admin, self.payload())
        self.expect("publication_pending", lambda: self.confirm(review))
        self.assertEqual(self.counts(), (1, 1, 0, 0))

    def test_original_job_binding_cannot_be_changed_or_removed(self):
        self.confirm(self.preview())
        for changed in (None, str(uuid.uuid4())):
            payload = self.review_request()
            document = payload["links"][2]
            if changed:
                document["serviceCallID"] = changed
            else:
                document.pop("serviceCallID")
            self.expect("job_changed", lambda: self.preview(payload))

    def test_review_expiry_is_rechecked_after_provider_reads(self):
        review = self.preview()
        future = datetime.now(timezone.utc) + timedelta(hours=1)
        self.before_read = lambda: setattr(self.adopter, "now", lambda: future)
        self.expect("review_expired", lambda: self.confirm(review))
        self.assertEqual(self.counts(), (0, 0, 0, 0))

    def test_ciphertext_or_scope_swap_is_rejected(self):
        first, second = self.preview(), self.preview()
        with backend.db() as connection:
            row = connection.execute("SELECT payload_ciphertext,revision FROM qbo_link_reviews WHERE id=?", (first["id"],)).fetchone()
            connection.execute("UPDATE qbo_link_reviews SET payload_ciphertext=?,revision=? WHERE id=?", (*row, second["id"]))
        self.expect("storage_unavailable", lambda: self.confirm(second))

    def test_failed_audit_rolls_back_every_mapping_and_decision(self):
        review = self.preview()
        self.adopter.audit = mock.Mock(side_effect=RuntimeError("fixture audit unavailable"))
        with self.assertRaises(RuntimeError):
            self.confirm(review)
        self.assertEqual(self.counts(), (0, 0, 0, 0))
        self.assertEqual(self.adopter.read(self.admin, review["id"])["state"], "review")

    def test_concurrent_confirmations_converge_on_same_identity(self):
        review = self.preview()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.confirm(review), range(2)))
        self.assertEqual(results[0], results[1])
        self.assertEqual(self.counts(), (1, 1, 2, 1))

    def test_strict_bounded_request_and_case_normalized_identities(self):
        for change in ({"role": "Admin"}, {"links": []}, {"links": [{}] * 26}, {"connectionRevision": "x"}, {"operationID": "../"}):
            self.expect("invalid_request", lambda: self.preview(self.review_request(**change))) if "operationID" not in change else self.assertRaises(adoption.AttemptError, lambda: self.preview(self.review_request(**change)))
        payload = self.review_request()
        payload["links"].append({**payload["links"][0], "localID": self.customer_id.upper()})
        self.expect("identity_conflict", lambda: self.preview(payload))
        review = self.preview()
        self.assertEqual(self.adopter.read(self.admin, review["id"].upper()), review)

    def test_paid_historical_invoice_link_does_not_authorize_updating_paid_history(self):
        self.remotes[2]["Balance"] = 50
        self.confirm(self.preview())
        from Backend import billing_publications
        self.expect("payment_review", lambda: billing_publications.verify_unpaid_update(
            {"Id": "D1", "SyncToken": "0", "CustomerRef": {"value": "C1"}}, self.remotes[2]))

    def test_backup_restore_preserves_confirmed_links_and_recovery_without_provider_reads(self):
        review = self.preview()
        confirmed = self.confirm(review)
        snapshot = sqlite3.connect(self.directory.name + "/restored.sqlite3")
        with backend.db() as connection:
            connection.backup(snapshot)
        snapshot.close()
        previous_reads = len(self.reads)
        with mock.patch.object(backend, "DB_PATH", backend.Path(self.directory.name) / "restored.sqlite3"):
            self.assertEqual(self.adopter.read(self.admin, review["id"]), confirmed)
            self.assertEqual(self.confirm(review), confirmed)
            self.assertEqual(self.counts(), (1, 1, 2, 1))
        self.assertEqual(len(self.reads), previous_reads)

    def test_missing_record_and_incomplete_evidence_never_save_partial_batch(self):
        self.remotes.pop()
        self.expect("provider_unavailable", self.preview)
        self.assertEqual(self.counts(), (0, 0, 0, 0))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM qbo_link_reviews").fetchone()[0], 0)

    def test_second_admin_can_recover_original_review_without_changing_actor_authority(self):
        review = self.preview()
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Admin' WHERE role='Accounting'")
        other = self.sessions["Accounting"]
        self.assertEqual(self.adopter.read(other, review["id"]), review)
        confirmed = self.adopter.decide(other, review["id"], review["revision"], confirm=True)
        self.assertEqual(confirmed["state"], "confirmed")
        self.assertFalse(self.writes)

    def test_adopted_unpaid_invoice_mapping_can_enter_shared_update_engine(self):
        self.confirm(self.preview())
        payload = self.payload(operation="update")
        payload["document"].update(Id="D1", SyncToken="0", sparse=True)
        # Preserve the actual existing customer/item/document IDs, not replacements.
        self.remotes = [self.remotes[2]]
        result = self.publish(payload)
        self.assertEqual(result["publication"]["providerID"], "D1")
        self.assertEqual(self.writes[0][1]["Id"], "D1")
        self.assertEqual(self.writes[0][1]["Line"][0]["Amount"], 189)

    @contextmanager
    def http(self, *, real_adapter=False):
        def factory(context, authorize, bearer):
            if not real_adapter:
                return self.provider(context, authorize)
            def send(request):
                self.assertEqual(request.get_method(), "GET")
                url = urllib.parse.urlsplit(request.full_url)
                self.assertEqual(url.hostname, "sandbox-quickbooks.api.intuit.com")
                resource, identifier = url.path.split("/")[-2:]
                kind = {"customer": "Customer", "item": "Item", "invoice": "Invoice", "estimate": "Estimate"}[resource]
                return {kind: self.provider(context, authorize).read(kind, identifier)}
            return billing_provider.BillingQBOProvider(context, authorize, lambda *_: "fixture-bearer", send=send)
        with mock.patch.object(backend, "BillingQBOProvider", side_effect=factory):
            server = backend.ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            def request(path, payload=None, role="Admin", raw=None):
                req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}" + path,
                    data=raw if raw is not None else json.dumps(payload).encode() if payload is not None else None,
                    headers={"Authorization": "Bearer " + self.tokens[role], "Content-Type": "application/json"})
                try:
                    with urllib.request.urlopen(req, timeout=5) as response:
                        return response.status, json.load(response)
                except urllib.error.HTTPError as error:
                    return error.code, json.load(error)
            try:
                yield request
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=5)

    def test_http_adapter_review_confirm_recover_uses_only_exact_provider_reads(self):
        with self.http(real_adapter=True) as request:
            status, review = request("/api/qbo-link-reviews", self.review_request())
            self.assertEqual(status, 200)
            status, result = request("/api/qbo-link-reviews/" + review["id"] + "/confirm", {"revision": review["revision"]})
            self.assertEqual((status, result["state"]), (200, "confirmed"))
            self.assertEqual(request("/api/qbo-link-reviews/" + review["id"]), (200, result))
        self.assertEqual(self.counts(), (1, 1, 2, 1))
        self.assertFalse(self.writes)

    def test_http_rejects_duplicates_nonfinite_unknown_fields_and_staff_roles(self):
        with self.http() as request:
            self.assertEqual(request("/api/qbo-link-reviews", raw=b'{"links":[],"links":[]}')[0], 400)
            self.assertEqual(request("/api/qbo-link-reviews", raw=b'{"links":NaN}')[0], 400)
            self.assertEqual(request("/api/qbo-link-reviews", self.review_request(), role="Standard")[0], 403)
            self.assertEqual(request("/api/qbo-link-reviews?" + urllib.parse.urlencode({**self.query(), "url": "https://outside.invalid"}))[0], 400)
            review = self.preview()
            self.assertEqual(request("/api/qbo-link-reviews/" + review["id"] + "/confirm", {"revision": review["revision"], "force": True})[0], 400)
