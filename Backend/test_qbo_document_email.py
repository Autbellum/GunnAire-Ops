from __future__ import annotations

import copy
import hashlib
import json
import threading
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import qbo_document_email as email
from Backend import qbo_document_email_provider as provider_adapter
from Backend import billing_assignments
from Backend.test_billing_publications import BillingFixture


class DocumentEmailTests(BillingFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.publish(self.estimate())
        self.document = copy.deepcopy(self.remotes[0])
        self.sends = 0
        self.lost_response = False
        self.no_provider_change = False
        self.now = datetime(2026, 10, 1, 18, 0, tzinfo=timezone.utc)
        fixture = self

        class Provider:
            def __init__(self, context, authorize):
                self.authorize = authorize

            def read_customer(self, identifier):
                self.authorize()
                return {"Id": identifier, "PrimaryEmailAddr": {"Address": "customer@example.invalid"}}

            def read(self, kind, identifier):
                self.authorize()
                return copy.deepcopy(fixture.document)

            def send(self, kind, identifier, recipient):
                self.authorize()
                fixture.sends += 1
                if not fixture.no_provider_change:
                    fixture.document.update(BillEmail={"Address": recipient}, EmailStatus="EmailSent",
                                            DeliveryInfo={"DeliveryType": "Email", "DeliveryTime":
                                                          (fixture.now + timedelta(seconds=1)).isoformat()})
                if fixture.lost_response:
                    raise TimeoutError("fixture response lost after provider acceptance")
                return copy.deepcopy(fixture.document)

        self.journal = email.DocumentEmailJournal(backend.db, self.publisher, Provider,
                                                 backend.record_audit_event, now=lambda: self.now)

    def request(self, **changes):
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox",
                "documentType": "Estimate", "providerID": "D1", "customerProviderID": "C1",
                "recipient": "customer@example.invalid", **changes}

    def row(self):
        with backend.db() as connection:
            return dict(connection.execute("SELECT * FROM qbo_document_email_attempts").fetchone())

    def test_explicit_action_sends_once_and_followup_reconciles(self):
        first = self.journal.run(self.admin, self.request())
        second = self.journal.run(self.admin, self.request())
        self.assertEqual(first["state"], "accepted")
        self.assertEqual(second, {"state": "reconciled"})
        self.assertEqual(self.sends, 1)
        self.assertEqual(self.row()["state"], "accepted")

    def test_lost_response_observes_matching_email_without_attributing_original_attempt(self):
        self.lost_response = True
        self.expect("review_required", lambda: self.journal.run(self.admin, self.request()))
        self.assertEqual(self.row()["state"], "unknown")
        self.assertEqual(self.journal.run(self.sessions["Dispatcher"], self.request()), {"state": "observed"})
        self.assertEqual(self.row()["state"], "observed")
        self.assertEqual(self.sends, 1)

    def test_independent_manual_send_after_unknown_is_observed_not_claimed_as_our_send(self):
        self.lost_response = True
        self.no_provider_change = True
        self.expect("review_required", lambda: self.journal.run(self.admin, self.request()))
        self.document.update(BillEmail={"Address": "customer@example.invalid"}, EmailStatus="EmailSent",
                             DeliveryInfo={"DeliveryType": "Email", "DeliveryTime":
                                           (self.now + timedelta(seconds=3)).isoformat()})
        self.assertEqual(self.journal.run(self.admin, self.request()), {"state": "observed"})
        self.assertEqual(self.journal.run(self.admin, self.request()), {"state": "observed"})
        self.assertEqual(self.row()["state"], "observed")
        self.assertEqual(self.sends, 1)

    def test_unknown_without_provider_evidence_never_resends(self):
        self.lost_response = True
        self.no_provider_change = True
        self.expect("review_required", lambda: self.journal.run(self.admin, self.request()))
        self.expect("review_required", lambda: self.journal.run(self.sessions["Dispatcher"], self.request()))
        self.assertEqual(self.sends, 1)
        self.assertEqual(self.row()["state"], "unknown")

    def test_old_or_same_second_delivery_timestamp_cannot_reconcile_unknown_send(self):
        self.lost_response = True
        self.no_provider_change = True
        self.expect("review_required", lambda: self.journal.run(self.admin, self.request()))
        self.document.update(BillEmail={"Address": "customer@example.invalid"}, EmailStatus="EmailSent",
                             DeliveryInfo={"DeliveryType": "Email", "DeliveryTime":
                                           (self.now - timedelta(seconds=1)).isoformat()})
        self.expect("review_required", lambda: self.journal.run(self.admin, self.request()))
        self.assertEqual(self.sends, 1)

    def test_grant_replacement_cannot_recover_or_send_again(self):
        self.lost_response = True
        self.expect("review_required", lambda: self.journal.run(self.admin, self.request()))
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='replacement' WHERE id=1")
        self.expect("grant_changed", lambda: self.journal.run(self.admin, self.request()))
        self.assertEqual(self.sends, 1)

    def test_different_recipient_cannot_bypass_uncertain_document_fence(self):
        self.lost_response = True
        self.no_provider_change = True
        self.expect("review_required", lambda: self.journal.run(self.admin, self.request()))
        self.expect("recipient_changed", lambda: self.journal.run(self.admin, self.request(recipient="other@example.invalid")))
        self.assertEqual(self.sends, 1)

    def test_preexisting_email_requires_review_without_post(self):
        self.document.update(BillEmail={"Address": "customer@example.invalid"}, EmailStatus="EmailSent",
                             DeliveryInfo={"DeliveryType": "Email", "DeliveryTime": self.now.isoformat()})
        self.expect("review_required", lambda: self.journal.run(self.admin, self.request()))
        self.assertEqual(self.sends, 0)
        self.document.pop("BillEmail")
        self.expect("review_required", lambda: self.journal.run(self.admin, self.request()))
        self.assertEqual(self.sends, 0)

    def test_mapping_customer_role_and_grant_are_required(self):
        self.expect("customer_changed", lambda: self.journal.run(self.admin, self.request(customerProviderID="C2")))
        self.expect("review_required", lambda: self.journal.run(self.sessions["Standard"], self.request()))
        with backend.db() as connection:
            connection.execute("DELETE FROM billing_entity_mappings")
        self.expect("mapping_required", lambda: self.journal.run(self.admin, self.request()))
        self.assertEqual(self.sends, 0)

    def test_current_assigned_field_technician_cannot_bypass_server_consent_boundary(self):
        import uuid
        job_id = str(uuid.uuid4())
        with backend.db() as connection:
            grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
            revision = billing_assignments.connection_revision(billing_assignments.grant_fingerprint(grant))
        assignment = {"companyID": self.company, "realmID": "realm", "environment": "sandbox",
                      "serviceCallID": job_id, "localCustomerID": self.customer_id,
                      "technicianEmails": [self.email("Field Technician")], "enabled": True,
                      "expectedRevision": 0, "operationID": str(uuid.uuid4()), "connectionRevision": revision}
        self.publisher.assignments.save(self.sessions["Dispatcher"], assignment)
        with backend.db() as connection:
            connection.execute("INSERT INTO billing_job_documents VALUES (?,?,?,?,?,?,?)",
                               (self.company, "realm", "sandbox", "Estimate", self.local_id,
                                job_id, self.customer_id))
        self.expect("review_required", lambda: self.journal.run(self.sessions["Field Technician"], self.request()))
        self.assertEqual(self.sends, 0)

    def test_field_technician_invoice_email_fails_closed(self):
        with backend.db() as connection:
            connection.execute("UPDATE billing_entity_mappings SET document_type='Invoice'")
        self.document["Id"] = "D1"
        self.expect("review_required", lambda: self.journal.run(self.sessions["Field Technician"],
            self.request(documentType="Invoice")))
        self.assertEqual(self.sends, 0)

    def test_atomic_claim_blocks_two_staff_devices(self):
        barrier = threading.Barrier(2)
        original = self.journal.authorize
        def authorize(*args, **kwargs):
            result = original(*args, **kwargs)
            if kwargs.get("expected_grant") is None:
                try:
                    barrier.wait(timeout=2)
                except threading.BrokenBarrierError:
                    pass
            return result
        self.journal.authorize = authorize
        with ThreadPoolExecutor(max_workers=2) as pool:
            operations = [pool.submit(self.journal.run, self.sessions[role], self.request())
                          for role in ("Admin", "Dispatcher")]
            outcomes = []
            for operation in operations:
                try:
                    outcomes.append(operation.result(timeout=5)["state"])
                except email.billing_publications.AttemptError as error:
                    outcomes.append(error.code)
        self.assertEqual(self.sends, 1)
        self.assertIn("accepted", outcomes)
        self.assertTrue(set(outcomes) <= {"accepted", "reconciled", "review_required"})

    def test_recipient_digest_and_no_customer_address_in_journal(self):
        self.journal.run(self.admin, self.request())
        row = self.row()
        self.assertEqual(row["recipient_digest"], hashlib.sha256(b"customer@example.invalid").hexdigest())
        self.assertNotIn("customer@example.invalid", repr(row))

    def test_fixed_origin_provider_transport_rejects_other_resources(self):
        import urllib.request
        for url in ("https://attacker.invalid/v3/company/realm/estimate/D1/send?minorversion=75&sendTo=x%40example.invalid",
                    "https://sandbox-quickbooks.api.intuit.com/v3/company/realm/estimate/D1/send?minorversion=75&sendTo=x%40example.invalid"):
            request = urllib.request.Request(url, method="GET")
            with self.assertRaises(email.billing_publications.AttemptError):
                provider_adapter.transport(request)

    def test_provider_adapter_uses_fixed_resource_and_original_recipient(self):
        seen = []
        def transport(request):
            seen.append(request)
            kind = "Customer" if "/customer/" in request.full_url else "Estimate"
            identifier = "C1" if kind == "Customer" else "D1"
            return {kind: {"Id": identifier}}
        provider = provider_adapter.DocumentEmailQBOProvider(
            {"realm_id": "realm", "environment": "sandbox"}, lambda: None,
            lambda context, actor: "synthetic-bearer", send=transport)
        self.assertEqual(provider.read_customer("C1")["Id"], "C1")
        self.assertEqual(provider.send("Estimate", "D1", "customer@example.invalid")["Id"], "D1")
        self.assertEqual([request.get_method() for request in seen], ["GET", "POST"])
        self.assertEqual(seen[1].get_header("Content-type"), "application/octet-stream")
        self.assertIn("sendTo=customer%40example.invalid", seen[1].full_url)
        self.assertTrue(seen[1].full_url.startswith("https://sandbox-quickbooks.api.intuit.com/v3/company/realm/estimate/D1/send?"))

    def test_authenticated_route_is_disabled_without_server_consent_authority(self):
        self.assertFalse(backend.QBO_DOCUMENT_EMAIL_ENABLED)
        provider_guard = mock.patch.object(backend, "DocumentEmailQBOProvider")
        provider = provider_guard.start()
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            request = urllib.request.Request(
                "http://127.0.0.1:" + str(server.server_port) + "/api/qbo-document-emails",
                data=json.dumps(self.request()).encode(),
                headers={"Authorization": "Bearer " + self.tokens["Admin"], "Content-Type": "application/json"})
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request, timeout=5)
            self.assertEqual(caught.exception.code, 501)
            self.assertEqual(json.load(caught.exception)["code"], "backend_upgrade_required")
            provider.assert_not_called()
            self.assertEqual(self.sends, 0)
            with backend.db() as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM qbo_document_email_attempts").fetchone()[0], 0)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
            provider_guard.stop()

    def test_authenticated_http_action_uses_same_durable_server_fence(self):
        self.now = datetime.now(timezone.utc)
        factory = lambda context, authorize, bearer: self.journal.provider_factory(context, authorize)
        with mock.patch.object(backend, "QBO_DOCUMENT_EMAIL_ENABLED", True), \
             mock.patch.object(backend, "DocumentEmailQBOProvider", side_effect=factory), \
             mock.patch.object(backend, "qbo_authorized_bearer") as credentials:
            server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                def post(token, raw):
                    request = urllib.request.Request(
                        "http://127.0.0.1:" + str(server.server_port) + "/api/qbo-document-emails",
                        data=raw, headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
                    try:
                        with urllib.request.urlopen(request, timeout=5) as response:
                            return response.status, json.load(response)
                    except urllib.error.HTTPError as error:
                        return error.code, json.load(error)
                body = json.dumps(self.request()).encode()
                self.assertEqual(post("bad-token", body)[0], 401)
                first = post(self.tokens["Admin"], body)
                second = post(self.tokens["Dispatcher"], body)
                self.assertEqual(first[0], 200, first)
                self.assertEqual(first[1]["state"], "accepted")
                self.assertEqual(second, (200, {"state": "reconciled"}))
                self.assertEqual(self.sends, 1)
                self.assertEqual(post(self.tokens["Admin"], b'{"recipient":"a","recipient":"b"}')[0], 400)
                credentials.assert_not_called()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
