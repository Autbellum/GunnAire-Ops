from __future__ import annotations

import copy
import unittest
import urllib.parse
import uuid

from Backend import gunnaire_backend as backend, billing_publications as billing, billing_native
from Backend import test_billing_assignments as fixture
from Backend.test_billing_publications import BillingFixture


class NativeBillingTests(BillingFixture, unittest.TestCase):
    assignment = fixture.BillingAssignmentTests.assignment
    save_assignment = fixture.BillingAssignmentTests.save_assignment
    field_payload = fixture.BillingAssignmentTests.field_payload
    http = fixture.BillingAssignmentTests.http

    def setUp(self):
        super().setUp()
        self.job_id = str(uuid.uuid4())
        self.jobs = self.publisher.assignments
        self.native = billing_native.NativeBilling(self.publisher)
        self.preflight.return_value = {"I1": {"Id": "I1", "Active": True, "Type": "Service", "UnitPrice": 189, "Taxable": False}}

    def query(self, **changes):
        keys = ("companyID", "realmID", "environment", "documentType", "localDocumentID", "localCustomerID", "serviceCallID")
        return {key: value for key, value in self.payload(serviceCallID=self.job_id, **changes).items() if key in keys}

    def context(self, role="Admin", query=None):
        return self.native.context(self.sessions[role], query or self.query())

    def mapped(self, kind="Invoice"):
        with backend.db() as connection:
            connection.execute("INSERT INTO billing_entity_mappings VALUES (?,'realm','sandbox',?,?,?,'D1')",
                               (self.company, kind, self.local_id, self.customer_id))
        self.remotes = [self.remote()]

    def test_office_context_keeps_unassigned_job_and_requires_no_assignment_claim(self):
        context = self.context("Accounting")
        self.assertEqual(context["serviceCallID"], self.job_id)
        self.assertEqual(context["customerProviderID"], "C1")
        self.assertIsNone(context["assignment"])
        self.assertIsNone(context["document"])
        self.assertEqual(context["authority"], "office")
        self.publish(self.payload(serviceCallID=self.job_id), "Accounting")
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT service_call_id FROM billing_job_documents").fetchone()[0], self.job_id)

    def test_context_roles_follow_billing_kind(self):
        for role in ("Dispatcher", "Standard", "Field Technician"):
            self.expect("access_denied", lambda: self.context(role))
        self.context("Dispatcher", self.query(documentType="Estimate"))
        self.expect("access_denied", lambda: self.context("Accounting", self.query(documentType="Estimate")))
        self.assertFalse(self.writes)

    def test_assigned_technician_cannot_read_an_unbound_existing_customer_invoice(self):
        self.save_assignment()
        self.mapped()
        self.expect("access_denied", lambda: self.context("Field Technician"))
        self.context("Accounting")
        with backend.db() as connection:
            self.jobs.bind_document(connection, billing.validated_request(self.field_payload()))
        self.assertEqual(self.context("Field Technician")["document"]["Id"], "D1")
        self.assertFalse(self.writes)

    def test_assigned_field_context_uses_server_roster_and_current_connection(self):
        self.save_assignment()
        result = self.context("Field Technician")
        self.assertEqual(result["authority"], "assigned")
        self.assertEqual(result["assignment"]["revision"], 1)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='replacement'")
        self.expect("access_denied", lambda: self.context("Field Technician"))
        self.assertFalse(self.writes)

    def test_context_rejects_missing_mapping_wrong_customer_job_and_scope(self):
        for changes, code in (({"companyID": str(uuid.uuid4())}, "company_changed"), ({"realmID": "other"}, "provider_changed"),
                              ({"environment": "production"}, "provider_changed"), ({"localCustomerID": str(uuid.uuid4())}, "customer_review")):
            self.expect(code, lambda: self.context(query=self.query(**changes)))
        self.save_assignment()
        self.expect("customer_changed", lambda: self.context(query=self.query(localCustomerID=str(uuid.uuid4()))))
        self.publish(self.payload(serviceCallID=self.job_id))
        query = self.query()
        query.pop("serviceCallID")
        self.expect("job_changed", lambda: self.context(query=query))

    def test_mapped_invoice_and_imported_estimate_are_read_without_new_lineage_or_write(self):
        for kind in ("Invoice", "Estimate"):
            self.mapped(kind)
            self.remotes[0]["Line"][0].update(Id="1", LineNum=1)
            self.remotes[0]["Line"].append({"Amount": 189, "DetailType": "SubTotalLineDetail", "SubTotalLineDetail": {}})
            result = self.context(query=self.query(documentType=kind))
            self.assertEqual(result["document"]["Id"], "D1")
            self.assertEqual(result["document"]["SyncToken"], "0")
            self.assertEqual(result["document"]["TxnDate"], "2026-09-07")
            self.assertEqual(len(result["document"]["Line"]), 1)
        self.assertFalse(self.writes)

    def test_mapped_read_rejects_wrong_customer_foreign_lineage_dates_totals_or_missing_token(self):
        self.mapped()
        original = copy.deepcopy(self.remotes[0])
        for changes in ({"CustomerRef": {"value": "other"}}, {"SyncToken": None}, {"TxnDate": "2026-02-31"},
                        {"TotalAmt": 190}, {"Balance": 190}, {"TxnTaxDetail": {}}, {"CurrencyRef": {"value": "EUR"}},
                        {"PrivateNote": "GunnAire Invoice ID: " + str(uuid.uuid4()).upper()}):
            self.remotes = [{**copy.deepcopy(original), **changes}]
            with self.subTest(changes=changes), self.assertRaises(billing.AttemptError):
                self.context()
        self.assertFalse(self.writes)

    def test_mapped_read_rechecks_roles_connection_customer_and_mapping_after_provider_wait(self):
        self.mapped()
        for statement in ("UPDATE users SET is_active=0 WHERE role='Admin'", "UPDATE qbo_connections SET authorized_at='reconnected'",
                          "UPDATE customer_entity_mappings SET provider_id='C2'", "UPDATE billing_entity_mappings SET provider_id='D2'"):
            with self.subTest(statement=statement):
                def changed():
                    with backend.db() as connection:
                        connection.execute(statement)
                self.before_read = changed
                with self.assertRaises(billing.AttemptError):
                    self.context()
                with backend.db() as connection:
                    connection.execute("UPDATE users SET is_active=1")
                    connection.execute("UPDATE qbo_connections SET authorized_at='grant'")
                    connection.execute("UPDATE customer_entity_mappings SET provider_id='C1'")
                    connection.execute("UPDATE billing_entity_mappings SET provider_id='D1'")
        self.assertFalse(self.writes)

    def test_retained_proposal_cannot_adopt_a_reconnected_grant(self):
        payload = self.payload()
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='reconnected'")
        self.expect("grant_changed", lambda: self.publish(payload))
        self.assertFalse(self.writes)

    def test_missing_or_malformed_epoch_cannot_prepare_publication(self):
        for value in (None, "", "A" * 64, "x" * 64, 1):
            self.expect("invalid_request", lambda: self.publish(self.payload(connectionRevision=value)))
        missing = self.payload()
        missing.pop("connectionRevision")
        self.expect("invalid_request", lambda: self.publish(missing))
        self.assertFalse(self.writes)

    def test_original_proposal_is_read_only_and_office_approves_exact_technician_prices(self):
        self.save_assignment()
        payload = self.field_payload()
        payload["document"]["Line"][0]["Amount"] = 200
        payload["document"]["Line"][0]["SalesItemLineDetail"]["UnitPrice"] = 200
        with self.assertRaises(billing.AttemptError):
            self.publish(payload, "Field Technician")
        identifier = self.row()["id"]
        original = self.native.proposal(self.admin, identifier)
        self.assertEqual(original["publication"]["state"], "reserved")
        self.assertEqual(original["proposal"]["document"]["Line"][0]["Amount"], 200)
        self.assertFalse(self.writes)
        self.native.approve_original(self.admin, identifier, {"proposal": original["proposal"]})
        self.assertFalse(self.writes)
        published = self.publish(original["proposal"], "Field Technician")
        self.assertEqual(published["document"]["TotalAmt"], 200)
        self.assertEqual(len(self.writes), 1)

    def test_office_review_cannot_approve_modified_cancelled_sent_or_office_original(self):
        self.save_assignment()
        payload = self.field_payload()
        row = self.publisher.reserve(self.sessions["Field Technician"], payload)
        original = self.native.proposal(self.admin, row["id"])["proposal"]
        changed = copy.deepcopy(original)
        changed["document"]["PrivateNote"] = "different"
        self.expect("proposal_changed", lambda: self.native.approve_original(self.admin, row["id"], {"proposal": changed}))
        self.expect("review_required", lambda: self.native.approve_original(self.sessions["Field Technician"], row["id"], {"proposal": original}))
        self.publisher.cancel(self.admin, row["id"])
        self.expect("proposal_changed", lambda: self.native.approve_original(self.admin, row["id"], {"proposal": original}))
        self.assertFalse(self.writes)

    def test_original_proposal_requires_current_business_role_and_grant(self):
        row = self.publisher.reserve(self.admin, self.payload())
        self.expect("review_required", lambda: self.native.proposal(self.sessions["Standard"], row["id"]))
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='replacement'")
        original = self.native.proposal(self.admin, row["id"])
        self.assertTrue(original["connectionChanged"])
        self.assertFalse(original["reviewableByOffice"])
        self.expect("grant_changed", lambda: self.native.approve_original(self.admin, row["id"], {"proposal": original["proposal"]}))
        self.assertEqual(self.publisher.cancel(self.admin, row["id"])["publication"]["state"], "cancelled")
        self.assertFalse(self.writes)

    def test_native_draft_revision_survives_server_normalization_and_must_be_valid(self):
        payload = self.payload(draftRevision="d" * 64)
        row = self.publisher.reserve(self.admin, payload)
        self.assertEqual(self.native.proposal(self.admin, row["id"])["proposal"]["draftRevision"], "d" * 64)
        for invalid in ("", "D" * 64, None, 7):
            self.expect("invalid_request", lambda: self.publish(self.payload(draftRevision=invalid)))
        self.assertFalse(self.writes)

    def test_cancel_racing_exact_office_approval_is_rechecked_inside_transaction(self):
        self.save_assignment()
        row = self.publisher.reserve(self.sessions["Field Technician"], self.field_payload())
        proposal = self.native.proposal(self.admin, row["id"])["proposal"]
        approve = self.publisher.approve_draft
        def race(*args, **kwargs):
            self.publisher.cancel(self.admin, row["id"])
            return approve(*args, **kwargs)
        self.publisher.approve_draft = race
        self.expect("proposal_changed", lambda: self.native.approve_original(self.admin, row["id"], {"proposal": proposal}))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM billing_draft_grants").fetchone()[0], 0)
        self.assertFalse(self.writes)

    def test_reconnected_office_cannot_cancel_consumed_attempt_or_another_company(self):
        self.publish()
        identifier = self.row()["id"]
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='replacement'")
        self.expect("publication_pending", lambda: self.publisher.cancel(self.admin, identifier))
        with backend.db() as connection:
            connection.execute("UPDATE company_identity SET company_id=?", (str(uuid.uuid4()),))
        self.expect("company_changed", lambda: self.native.proposal(self.admin, identifier))
        self.expect("company_changed", lambda: self.publisher.cancel(self.admin, identifier))
        self.assertEqual(len(self.writes), 1)

    def test_http_context_and_original_review_use_existing_session_and_exact_shapes(self):
        row = self.publisher.reserve(self.admin, self.payload())
        with self.http() as request:
            path = "/api/billing-publications/context?" + urllib.parse.urlencode(self.query())
            status, context = request(path)
            self.assertEqual(status, 200)
            self.assertEqual(context["customerProviderID"], "C1")
            status, original = request("/api/billing-publications/" + row["id"])
            self.assertEqual(status, 200)
            self.assertEqual(original["publication"]["id"], row["id"])
            self.assertEqual(request(path, role="Standard")[0], 403)
            self.assertEqual(request(path + "&realmID=other")[0], 400)
            self.assertEqual(request("/api/billing-publications/" + row["id"] + "?ignored=1")[0], 404)
            self.assertEqual(request("/api/billing-publications/" + row["id"] + "/approve", {"proposal": original["proposal"], "technicianEmail": "forged@example.invalid"})[0], 400)
        self.assertFalse(self.writes)
