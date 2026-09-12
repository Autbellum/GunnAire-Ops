from __future__ import annotations

import copy
import threading
import unittest
import uuid
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

from Backend import billing_milestones as milestones, billing_native, billing_publications as billing
from Backend import gunnaire_backend as backend
from Backend.test_billing_publications import BillingFixture
from Backend import test_billing_assignments as assignment_fixture


class MilestoneBillingTests(BillingFixture, unittest.TestCase):
    http = assignment_fixture.BillingAssignmentTests.http
    assignment = assignment_fixture.BillingAssignmentTests.assignment
    def setUp(self):
        super().setUp()
        self.stage, self.job = str(uuid.uuid4()), str(uuid.uuid4())
        self.job_id = self.job
        self.native = billing_native.NativeBilling(self.publisher)

    def stage_payload(self, **changes):
        return self.payload(**{"projectMilestoneID": self.stage, "serviceCallID": self.job, **changes})

    def legacy(self, **changes):
        value = self.payload(serviceCallID=self.job, **changes)
        value["document"]["PrivateNote"] = "GunnAire project billing: Progress Invoice 1 • Deposit; milestone ID " + self.stage.upper()
        return value

    def query(self, **changes):
        keys = {"companyID", "realmID", "environment", "localDocumentID", "documentType", "localCustomerID", "serviceCallID", "projectMilestoneID"}
        return {key: value for key, value in self.stage_payload(**changes).items() if key in keys}

    def insert_old(self, payload, state="reserved"):
        """Seed an actual pre-index encrypted proposal, not a new reservation."""
        value = billing.validated_request(payload)
        identifier, now = str(uuid.uuid4()), backend.utc_now()
        with backend.db() as connection:
            grant = connection.execute("SELECT * FROM qbo_connections WHERE id=1").fetchone()
            connection.execute("INSERT INTO billing_publications VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,?,?,?)",
                (identifier, *billing.document_scope(value), value["local_customer_id"], value["operation"], billing.digest(value),
                 backend.encrypt_catalog_payload(billing.canonical(value)), billing.grant_fingerprint(grant),
                 "ga-invoice-" + value["local_document_id"], state, self.email("Admin"), now, now))
        return identifier

    def test_concurrent_different_device_uuids_have_one_original_and_one_write(self):
        barrier = threading.Barrier(2)
        values = [self.stage_payload(), self.stage_payload(localDocumentID=str(uuid.uuid4()))]
        def publish(payload):
            barrier.wait()
            try:
                return self.publish(payload)["publication"]["localDocumentID"]
            except billing.AttemptError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            outcomes = list(pool.map(publish, values))
        self.assertEqual(outcomes.count("milestone_original"), 1)
        self.assertEqual(len(self.writes), 1)
        owner = next(value for value in outcomes if value != "milestone_original")
        for payload in values:
            context = self.native.context(self.admin, self.query(localDocumentID=payload["localDocumentID"]))
            self.assertEqual(context["milestone"]["localDocumentID"], owner)
            self.assertEqual(context["milestoneIdentityVersion"], 1)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM billing_publications").fetchone()[0], 1)

    def test_lost_reply_keeps_shared_original_across_publisher_restart(self):
        def lost(_):
            raise TimeoutError("Fixture lost response")
        self.after_write = lost
        payload = self.stage_payload()
        with self.assertRaises(TimeoutError):
            self.publish(payload)
        identifier = self.row()["id"]
        self.assertEqual(self.row()["state"], "unknown")
        self.publisher = billing.BillingPublisher(backend.db, self.provider, backend.encrypt_catalog_payload,
            backend.decrypt_catalog_payload, backend.record_audit_event)
        other = self.stage_payload(localDocumentID=str(uuid.uuid4()))
        self.expect("milestone_original", lambda: self.publish(other))
        result = self.publisher.run(self.admin, identifier)
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)

    def test_legacy_random_invoice_identity_is_retained_without_rewriting_hash(self):
        old = self.legacy()
        identifier = self.insert_old(old)
        prior = self.row()
        self.expect("milestone_original", lambda: self.publish(self.stage_payload(localDocumentID=str(uuid.uuid4()))))
        context = self.native.context(self.admin, self.query(localDocumentID=str(uuid.uuid4())))
        self.assertEqual(context["milestone"]["publicationID"], identifier)
        self.assertEqual(context["milestone"]["localDocumentID"], self.local_id)
        self.assertEqual(self.row()["payload_ciphertext"], prior["payload_ciphertext"])
        self.assertEqual(self.row()["payload_hash"], prior["payload_hash"])
        self.publish(old)
        self.assertEqual(len(self.writes), 1)

    def test_two_preexisting_offline_proposals_cannot_pick_a_winner_or_dispatch(self):
        first = self.insert_old(self.legacy())
        second = self.insert_old(self.legacy(localDocumentID=str(uuid.uuid4())))
        for identifier in (first, second):
            self.expect("milestone_history_conflict", lambda: self.publisher.claim(self.admin, identifier))
        self.expect("milestone_history_conflict", lambda: self.native.context(self.admin, self.query()))
        self.assertFalse(self.writes)

    def test_cancelled_unsent_request_keeps_invoice_identity_but_allows_its_revised_proposal(self):
        payload = self.stage_payload()
        first = self.publisher.reserve(self.admin, payload)
        self.publisher.cancel(self.admin, first["id"])
        self.expect("milestone_original", lambda: self.publish(self.stage_payload(localDocumentID=str(uuid.uuid4()))))
        changed = copy.deepcopy(payload)
        changed["document"]["DueDate"] = "2026-10-08"
        self.publish(changed)
        self.assertEqual(len(self.writes), 1)

    def test_marker_cannot_be_removed_or_reassigned_on_same_invoice(self):
        first = self.publisher.reserve(self.admin, self.legacy())
        self.publisher.cancel(self.admin, first["id"])
        for payload in (self.payload(serviceCallID=self.job), self.stage_payload(projectMilestoneID=str(uuid.uuid4()))):
            self.expect("milestone_review", lambda: self.publish(payload))
        self.assertFalse(self.writes)

    def test_wrong_job_customer_company_realm_or_environment_cannot_discover_original(self):
        self.publisher.reserve(self.admin, self.stage_payload())
        cases = [({"serviceCallID": str(uuid.uuid4())}, "milestone_review"),
                 ({"localCustomerID": str(uuid.uuid4())}, "customer_review"),
                 ({"companyID": str(uuid.uuid4())}, "company_changed"),
                 ({"realmID": "another"}, "provider_changed"), ({"environment": "production"}, "provider_changed")]
        for changes, code in cases:
            self.expect(code, lambda: self.native.context(self.admin, self.query(localDocumentID=str(uuid.uuid4()), **changes)))
        for role in ("Standard", "Dispatcher", "Field Technician"):
            self.expect("access_denied", lambda: self.native.context(self.sessions[role], self.query()))
        self.assertFalse(self.writes)

    def test_structured_identity_round_trips_without_changing_encrypted_proposal(self):
        payload = self.stage_payload(draftRevision="d" * 64)
        row = self.publisher.reserve(self.admin, payload)
        wire = self.native.proposal(self.admin, row["id"])["proposal"]
        self.assertEqual(wire["projectMilestoneID"], self.stage)
        self.assertEqual(billing.digest(billing.validated_request(wire)), row["payload_hash"])
        self.assertEqual(milestones.from_note(self.publisher.payload(row)["PrivateNote"]), self.stage)

    def test_invalid_or_conflicting_machine_references_do_not_claim_or_send(self):
        variants = ["GunnAire Milestone ID: incomplete", "GunnAire project billing: truncated",
            "GunnAire Milestone ID: " + str(uuid.uuid4()),
            ("GunnAire Milestone ID: " + self.stage + "\n") * 2]
        for note in variants:
            payload = self.stage_payload()
            payload["document"]["PrivateNote"] = note
            self.expect("milestone_review", lambda: self.publish(payload))
        self.assertFalse(self.writes)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM billing_publications").fetchone()[0], 0)

    def test_estimate_or_missing_job_cannot_claim_stage(self):
        value = self.stage_payload()
        value.pop("serviceCallID")
        self.expect("milestone_review", lambda: self.publish(value))
        value = self.estimate()
        value.update(projectMilestoneID=self.stage, serviceCallID=self.job)
        self.expect("milestone_review", lambda: self.publish(value))

    def test_provider_census_catches_legacy_stage_under_different_invoice_id(self):
        other = str(uuid.uuid4())
        remote = self.remote(self.legacy()["document"])
        remote["PrivateNote"] += "\nGunnAire Invoice ID: " + other.upper()
        self.remotes = [remote]
        self.expect("milestone_original", lambda: self.publish(self.stage_payload()))
        self.assertFalse(self.writes)
        self.assertEqual(self.row()["state"], "reserved")

    def test_provider_removing_milestone_after_acceptance_stays_unknown_without_retry(self):
        def removed(remote):
            remote["PrivateNote"] = "\n".join(line for line in remote["PrivateNote"].splitlines() if not line.startswith("GunnAire Milestone"))
            return remote
        self.after_write = removed
        self.expect("milestone_review", lambda: self.publish(self.stage_payload()))
        self.assertEqual(self.row()["state"], "unknown")
        self.assertEqual(len(self.writes), 1)

    def test_unauthorized_request_does_not_even_index_legacy_data(self):
        self.insert_old(self.legacy())
        self.expect("review_required", lambda: self.publish(self.stage_payload(), role="Standard"))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM billing_milestone_index").fetchone()[0], 0)

    def test_old_nonmilestone_proposal_is_indexed_once_and_ordinary_billing_works(self):
        self.insert_old(self.payload())
        self.native.context(self.admin, self.query(localDocumentID=str(uuid.uuid4())))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT milestone_id FROM billing_milestone_index").fetchone()[0], None)
        self.publish()
        self.assertEqual(len(self.writes), 1)

    def test_technician_job_assignment_is_not_milestone_approval_but_exact_office_grant_is(self):
        self.publisher.assignments.save(self.admin, self.assignment())
        payload = self.stage_payload(assignmentRevision=1)
        self.expect("review_required", lambda: self.publish(payload, role="Field Technician"))
        self.publisher.approve_draft(self.admin, payload, self.email("Field Technician"))
        self.publish(payload, role="Field Technician")
        self.assertEqual(len(self.writes), 1)

    def test_issued_allocation_cannot_be_repriced_via_invoice_update(self):
        payload = self.stage_payload()
        self.publish(payload)
        changed = copy.deepcopy(payload)
        changed["operation"] = "update"
        changed["document"].update(Id="D1", SyncToken="0", sparse=True)
        changed["document"]["Line"][0]["Amount"] = 200
        changed["document"]["Line"][0]["SalesItemLineDetail"]["UnitPrice"] = 200
        self.expect("milestone_allocation_changed", lambda: self.publish(changed))
        self.assertEqual(len(self.writes), 1)

    def test_reconnection_keeps_original_identity_without_reauthorizing_its_unsent_request(self):
        first = self.publisher.reserve(self.admin, self.stage_payload())
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='new-grant'")
        context = self.native.context(self.admin, self.query(localDocumentID=str(uuid.uuid4())))
        self.assertEqual(context["milestone"]["publicationID"], first["id"])
        self.expect("grant_changed", lambda: self.publisher.run(self.admin, first["id"], allow_send=True))
        self.assertFalse(self.writes)

    def test_http_lookup_and_conflict_are_authenticated_and_never_publish_a_replacement(self):
        payload = self.stage_payload()
        with self.http() as request:
            status, first = request("/api/billing-publications", payload)
            self.assertEqual(status, 200)
            query = self.query(localDocumentID=str(uuid.uuid4()))
            path = "/api/billing-publications/context?" + urllib.parse.urlencode(query)
            status, context = request(path)
            self.assertEqual(status, 200)
            self.assertEqual(context["milestone"]["publicationID"], first["publication"]["id"])
            self.assertEqual(context["milestoneIdentityVersion"], 1)
            self.assertEqual(request(path, role="Standard")[0], 403)
            self.assertEqual(request(path + "&projectMilestoneID=" + self.stage)[0], 400)
            other = self.stage_payload(localDocumentID=query["localDocumentID"])
            status, conflict = request("/api/billing-publications", other)
            self.assertEqual(status, 409)
            self.assertEqual(conflict["code"], "milestone_original")
        self.assertEqual(len(self.writes), 1)
