from __future__ import annotations

import copy
import json
import unittest
import urllib.parse
import uuid
from concurrent.futures import ThreadPoolExecutor
from unittest import mock

from Backend import gunnaire_backend as backend, cloudkit_staff_shares as shares
from Backend import staff_workspace_contract as contract, staff_workspace_selection as selection
from Backend import staff_workspace_selections as service
from Backend import test_cloudkit_staff_shares as sharing_fixtures, test_staff_workspace_source as source_fixtures


EMAIL = "field.technician@gunnaire.com"


def set_value(record, field, value):
    spec = contract.SPECS[record["kind"]][field]
    record["fields"][field] = {"null": {}} if value is None else {spec["type"]: {"_0": value.upper() if spec["type"] == "identifier" else value}}


def fixture_records(company="b1000000-0000-4000-8000-000000000001", replica="b1000000-0000-4000-8000-000000000002"):
    records = [dict(companyID=company, environment="development", replicaID=replica, schema=contract.SCHEMA_VERSION,
                    schemaDigest=contract.SCHEMA_DIGEST, kind=r["kind"], id=r["id"].lower(), revision=1, deleted=False,
                    fields=copy.deepcopy(r["fields"])) for r in source_fixtures.StaffWorkspaceSourceTests.native_records()]
    by = {r["kind"]: r for r in records}
    for kind, field in (("technician", "contactInfo"), ("user", "email"), ("timeEntry", "userEmail"),
                        ("timeOff", "requestedByEmail"), ("task", "assignedToEmail"), ("expense", "claimantEmail")):
        set_value(by[kind], field, EMAIL)
    set_value(by["invoice"], "serviceCallID", by["job"]["id"])
    set_value(by["job"], "serviceLocationID", by["location"]["id"])
    set_value(by["job"], "customerEquipmentID", by["equipment"]["id"])
    set_value(by["equipment"], "serviceLocationID", by["location"]["id"])
    set_value(by["vehicle"], "assignedTechnicianID", by["technician"]["id"])
    set_value(by["task"], "serviceCallID", by["job"]["id"])
    return records


def row(records, kind):
    return next(r for r in records if r["kind"] == kind)


def clone(record):
    result = copy.deepcopy(record)
    result["id"] = str(uuid.uuid4())
    return result


class FullStaffSelectionPolicyTests(unittest.TestCase):
    def index(self, records, role="Field Technician", email=EMAIL):
        return selection.Graph(records).index(role, email)

    def selected(self, records, role="Field Technician", email=EMAIL):
        return {(r["kind"], r["id"]) for r in self.index(records, role, email)}

    def test_all_32_kinds_and_every_typed_identifier_are_explicitly_classified(self):
        self.assertEqual(len(selection.rules()), 32)
        records = fixture_records()
        self.assertEqual(len(self.index(records, "Admin")), 32)
        self.assertEqual({r["kind"] for r in self.index(records)}, set(contract.SPECS) - {"estimate", "request"})
        with mock.patch.object(contract, "SCHEMA_DIGEST", "0" * 64):
            with self.assertRaises(shares.AttemptError):
                selection.Graph(records)

    def test_all_five_roles_have_specific_work_scopes_without_owner_values(self):
        records = fixture_records()
        self.assertEqual({r["kind"] for r in self.index(records, "Standard")}, {"user", "timeEntry", "task", "taskEvent"})
        dispatch = {r["kind"] for r in self.index(records, "Dispatcher")}
        self.assertNotIn("invoice", dispatch)
        self.assertNotIn("payment", dispatch)
        self.assertIn("estimate", dispatch)
        accounting = {r["kind"] for r in self.index(records, "Accounting")}
        self.assertIn("invoice", accounting)
        self.assertIn("payment", accounting)
        self.assertIn("expense", accounting)
        self.assertNotIn("timeOff", accounting)
        for role in shares.POLICIES:
            result = self.index(records, role)
            self.assertNotIn("Original", json.dumps(result))
            for value in result:
                self.assertEqual(set(value), {"kind", "id", "revision", "unavailableLinks"})

    def test_only_assignment_not_same_customer_grants_invoice_or_other_property(self):
        records = fixture_records()
        invoice = clone(row(records, "invoice"))
        set_value(invoice, "serviceCallID", None)
        location = clone(row(records, "location"))
        equipment = clone(row(records, "equipment"))
        set_value(equipment, "serviceLocationID", location["id"])
        selected = self.selected(records + [invoice, location, equipment])
        for value in (invoice, location, equipment):
            self.assertNotIn((value["kind"], value["id"]), selected)

    def test_crew_identity_missing_mapping_and_duplicate_mapping_fail_without_broadening(self):
        records = fixture_records()
        tech = row(records, "technician")
        other = clone(tech)
        set_value(other, "contactInfo", "other@example.invalid")
        set_value(row(records, "job"), "assignedTechnician", other["id"])
        set_value(row(records, "job"), "additionalTechnicianIDsJSON", json.dumps([tech["id"].upper()]))
        self.assertIn(("invoice", row(records, "invoice")["id"]), self.selected(records + [other]))
        duplicate = clone(tech)
        with self.assertRaises(shares.AttemptError) as failure:
            self.index(records + [other, duplicate])
        self.assertEqual(failure.exception.code, "identity_ambiguous")
        set_value(tech, "contactInfo", None)
        with self.assertRaises(shares.AttemptError) as failure:
            self.index(records + [other])
        self.assertEqual(failure.exception.code, "identity_pending")

    def test_other_employee_hr_time_expenses_and_self_tasks_are_not_granted(self):
        records = fixture_records()
        others = []
        for kind, field in (("timeEntry", "userEmail"), ("expense", "claimantEmail"), ("task", "assignedToEmail"), ("user", "email")):
            other = clone(row(records, kind))
            set_value(other, field, "other@example.invalid")
            others.append(other)
        other_tech = clone(row(records, "technician"))
        set_value(other_tech, "contactInfo", "other@example.invalid")
        others.append(other_tech)
        for kind in ("availability", "shift", "timeOff", "availabilityEvent"):
            other = clone(row(records, kind))
            set_value(other, "technicianID", other_tech["id"])
            others.append(other)
        selected = self.selected(records + others)
        self.assertTrue(all((r["kind"], r["id"]) not in selected for r in others))
        set_value(row(records, "user"), "roleRawValue", "Admin")
        self.assertNotIn("invoice", {r["kind"] for r in self.index(records, "Standard")})

    def test_related_context_links_are_unavailable_not_null_or_implicit_new_record_grants(self):
        records = fixture_records()
        result = self.index(records, "Standard")
        task = next(r for r in result if r["kind"] == "task")
        self.assertEqual(task["unavailableLinks"], ["serviceCallID"])
        self.assertNotIn("job", {r["kind"] for r in result})

    def test_unapproved_other_worker_catalog_drafts_are_not_promoted_by_selection(self):
        records = fixture_records()
        own, other = clone(row(records, "item")), clone(row(records, "item"))
        for r, email in ((own, EMAIL), (other, "other@example.invalid")):
            set_value(r, "pricebookReviewStatusRawValue", "needs_review")
            set_value(r, "pricebookCreatedByEmail", email)
        selected = self.selected(records + [own, other])
        self.assertIn(("item", own["id"]), selected)
        self.assertNotIn(("item", other["id"]), selected)

    def test_historical_templates_and_assigned_vehicle_stock_are_available_without_ambiguous_trucks(self):
        records = fixture_records()
        set_value(row(records, "formTemplate"), "isActive", False)
        self.assertIn(("formTemplate", row(records, "formTemplate")["id"]), self.selected(records))
        other = clone(row(records, "movement"))
        set_value(other, "serviceCallID", None)
        set_value(other, "sourceLocation", row(records, "vehicle")["fields"]["stockLocation"]["text"]["_0"])
        self.assertIn(("movement", other["id"]), self.selected(records + [other]))
        duplicate_vehicle = clone(row(records, "vehicle"))
        with self.assertRaises(shares.AttemptError) as failure:
            self.index(records + [duplicate_vehicle])
        self.assertEqual(failure.exception.code, "stock_identity_ambiguous")

    def test_allowed_job_cannot_expose_a_restricted_invoice_attachment_or_email(self):
        records = fixture_records()
        private = clone(row(records, "invoice"))
        set_value(private, "serviceCallID", None)
        for kind in ("attachment", "communication"):
            set_value(row(records, kind), "invoiceID", private["id"])
        selected = self.selected(records + [private])
        self.assertNotIn(("attachment", row(records, "attachment")["id"]), selected)
        self.assertNotIn(("communication", row(records, "communication")["id"]), selected)

    def test_own_receipt_survives_reassignment_without_granting_the_old_job_or_private_invoice(self):
        records = fixture_records()
        set_value(row(records, "job"), "assignedTechnician", None)
        attachment = row(records, "attachment")
        set_value(attachment, "kindRaw", "expense_receipt")
        set_value(attachment, "expenseClaimID", row(records, "expense")["id"])
        result = self.index(records)
        self.assertNotIn("job", {r["kind"] for r in result})
        visible = next(r for r in result if r["kind"] == "attachment")
        self.assertEqual(visible["unavailableLinks"], ["customer", "serviceCallID"])
        set_value(attachment, "invoiceID", row(records, "invoice")["id"])
        self.assertNotIn("attachment", {r["kind"] for r in self.index(records)})

    def test_account_statements_are_financial_even_with_generic_customer_document_kind(self):
        records = fixture_records()
        attachment = row(records, "attachment")
        set_value(attachment, "kindRaw", "customer_document")
        set_value(attachment, "displayName", "GunnAire-Account-Statement-Original.pdf")
        for role in ("Field Technician", "Dispatcher", "Standard"):
            self.assertNotIn(("attachment", attachment["id"]), self.selected(records, role))
        self.assertIn(("attachment", attachment["id"]), self.selected(records, "Accounting"))

    def test_every_relationship_requires_its_original_target_even_when_role_cannot_see_source(self):
        records = fixture_records()
        for kind, links in selection.rules().items():
            for field in links:
                with self.subTest(kind=kind, field=field):
                    broken = copy.deepcopy(records)
                    set_value(row(broken, kind), field, str(uuid.uuid4()))
                    with self.assertRaises(shares.AttemptError):
                        self.index(broken, "Standard")

    def test_transitive_customer_scope_conflicts_cycle_and_duplicate_lists_are_rejected(self):
        records = fixture_records()
        other_customer = clone(row(records, "customer"))
        set_value(row(records, "invoice"), "customer", other_customer["id"])
        with self.assertRaises(shares.AttemptError):
            self.index(records + [other_customer])
        records = fixture_records()
        set_value(row(records, "job"), "originatingServiceCallID", row(records, "job")["id"])
        with self.assertRaises(shares.AttemptError):
            self.index(records)
        records = fixture_records()
        own = row(records, "technician")["id"].upper()
        set_value(row(records, "job"), "additionalTechnicianIDsJSON", json.dumps([own, own]))
        with self.assertRaises(shares.AttemptError):
            self.index(records)

    def test_unknown_field_discriminator_mixed_source_duplicate_or_tombstone_does_not_disappear_silently(self):
        records = fixture_records()
        duplicate = records + [copy.deepcopy(records[0])]
        mixed = copy.deepcopy(records)
        mixed[0]["companyID"] = str(uuid.uuid4())
        unknown = copy.deepcopy(records)
        unknown[0]["fields"]["privateUnknown"] = {"text": {"_0": "do not export"}}
        kind = copy.deepcopy(records)
        set_value(row(kind, "attachment"), "kindRaw", "new_private_type")
        for invalid in (duplicate, mixed, unknown, kind):
            with self.assertRaises(shares.AttemptError):
                self.index(invalid, "Admin")
        tombstone = copy.deepcopy(records)
        row(tombstone, "vendor")["deleted"] = True
        self.assertNotIn("vendor", {r["kind"] for r in self.index(tombstone, "Admin")})

    def test_large_deep_job_history_is_iterative_complete_and_not_truncated(self):
        records = fixture_records()
        previous = row(records, "job")
        for _ in range(2000):
            next_job = clone(previous)
            set_value(next_job, "originatingServiceCallID", previous["id"])
            records.append(next_job)
            previous = next_job
        result = self.index(records)
        self.assertEqual(sum(r["kind"] == "job" for r in result), 2001)
        self.assertEqual(len(result), 2030)
        self.assertEqual(len({(r["kind"], r["id"]) for r in result}), len(result))


class FullStaffSelectionHTTPTests(unittest.TestCase):
    Fixture = sharing_fixtures.CloudKitStaffSharingTests
    setUp = Fixture.setUp
    tearDown = Fixture.tearDown
    request = Fixture.request
    workspace = Fixture.workspace
    binding_payload = Fixture.binding_payload
    bind = Fixture.bind
    prepare = Fixture.prepare
    enroll = Fixture.enroll
    change = Fixture.change
    requested = Fixture.requested
    advance = Fixture.advance
    accepted = Fixture.accepted
    root = Fixture.root
    participant_name = Fixture.participant_name
    participant_hash = Fixture.participant_hash

    def seed(self, role="Field Technician", extra=0):
        self.prepare()
        self.scope = dict(companyID=self.company, environment="development", replicaID=self.workspace()["bindings"][0]["replicaID"])
        records = fixture_records(self.company, self.scope["replicaID"])
        records += [clone(row(records, "vendor")) for _ in range(extra)]
        self.records = records
        sequence = 0
        for start in range(0, len(records), 100):
            self.write_source(records[start:start + 100], sequence)
            sequence += 1
        self.sequence = sequence
        self.share = self.accepted(role)
        self.endpoint = self.root + "/" + self.share["id"] + "/full-selections"
        self.payload = dict(**self.scope, operationID=str(uuid.uuid4()), expectedSourceSequence=sequence,
                            expectedShareRevision=self.share["revision"], sourceSchemaDigest=contract.SCHEMA_DIGEST)
        return self.post()

    def write_source(self, records, sequence, expected_revision=0):
        payload = dict(**self.scope, schema=contract.SCHEMA_VERSION, schemaDigest=contract.SCHEMA_DIGEST, operationID=str(uuid.uuid4()),
                       expectedSequence=sequence, changes=[dict(kind=r["kind"], id=r["id"], action="upsert", expectedRevision=expected_revision, fields=r["fields"]) for r in records])
        status, result = self.request(token=self.tokens["Admin"], path="/api/workspace/full-records", method="POST", payload=payload)
        self.assertEqual(status, 200, result)

    def post(self, payload=None, role="Admin"):
        return self.request(token=self.tokens[role], path=self.endpoint, method="POST", payload=payload or self.payload)

    def get(self, *, records=False, role="Admin", query=None, operation=None):
        path = self.endpoint + "/" + (operation or self.payload["operationID"]) + ("/records" if records else "")
        return self.request(token=self.tokens[role], path=path + "?" + urllib.parse.urlencode(query or self.scope))

    def count(self):
        with backend.db() as connection:
            return connection.execute("SELECT COUNT(*) FROM staff_workspace_selections").fetchone()[0]

    def test_real_http_selects_full_owner_source_with_no_core_relabeling_or_business_field_payload(self):
        status, receipt = self.seed()
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["schema"], selection.VERSION)
        self.assertEqual(receipt["coverage"], sorted(contract.SPECS))
        self.assertEqual(receipt["recordCount"], 30)
        self.assertTrue(receipt["fieldProjectionRequired"])
        self.assertFalse(receipt["operationalWorkspaceReady"])
        self.assertTrue(receipt["localCloudKitProofRequired"])
        status, page = self.get(records=True)
        self.assertEqual(status, 200, page)
        self.assertEqual(page["snapshotSHA256"], receipt["snapshotSHA256"])
        self.assertIsNone(page["nextCursor"])
        self.assertNotIn('"fields"', json.dumps(page))
        self.assertNotIn("Original", json.dumps(page))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_records").fetchone()[0], 0)
            ciphertext = connection.execute("SELECT ciphertext FROM staff_workspace_selections").fetchone()[0]
            self.assertNotIn(self.payload["operationID"], ciphertext)
            self.assertNotIn('"records"', ciphertext)

    def test_every_nonowner_is_denied_preparation_receipt_and_pages_including_the_target_member(self):
        self.assertEqual(self.seed()[0], 200)
        for role in self.tokens:
            if role != "Admin":
                self.assertEqual(self.post(role=role)[0], 403)
                self.assertEqual(self.get(role=role)[0], 403)
                self.assertEqual(self.get(role=role, records=True)[0], 403)
        self.assertEqual(self.count(), 1)

    def test_original_lost_reply_is_encrypted_immutable_and_recovers_after_database_restart(self):
        original = self.seed()
        self.assertEqual(original[0], 200)
        backend.initialize_database()
        self.assertEqual(self.post(), original)
        self.assertEqual(self.get(), original)
        self.assertEqual(self.count(), 1)
        with ThreadPoolExecutor(max_workers=4) as pool:
            self.assertTrue(all(result == original for result in pool.map(lambda _: self.post(), range(4))))
        self.assertEqual(self.count(), 1)

    def test_source_change_keeps_original_receipt_but_refuses_stale_assignment_pages(self):
        status, original = self.seed()
        self.assertEqual(status, 200)
        changed = copy.deepcopy(row(self.records, "job"))
        set_value(changed, "assignedTechnician", None)
        self.write_source([changed], self.sequence, 1)
        status, recovered = self.post()
        self.assertEqual(status, 200, recovered)
        self.assertEqual(recovered["sourceSequence"], original["sourceSequence"])
        self.assertEqual(recovered["snapshotSHA256"], original["snapshotSHA256"])
        self.assertFalse(recovered["sourceCurrent"])
        self.assertEqual(self.get(records=True)[1]["code"], "source_changed")
        new = dict(self.payload, operationID=str(uuid.uuid4()), expectedSourceSequence=self.sequence + 1)
        self.assertEqual(self.post(new)[0], 200)
        status, page = self.get(records=True, operation=new["operationID"])
        self.assertEqual(status, 200, page)
        self.assertNotIn("invoice", {r["kind"] for r in page["records"]})

    def test_source_rollback_behind_a_committed_selection_requires_storage_recovery(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("DELETE FROM staff_workspace_source_heads")
        self.assertEqual(self.get()[0], 503)
        self.assertEqual(self.get(records=True)[0], 503)
        self.assertEqual(self.post()[0], 503)
        self.assertEqual(self.count(), 1)

    def test_same_operation_cannot_change_source_scope_request_or_creator(self):
        self.assertEqual(self.seed()[0], 200)
        changed = dict(self.payload, expectedSourceSequence=self.sequence + 1)
        self.assertEqual(self.post(changed)[1]["code"], "operation_changed")
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Admin' WHERE email='dispatcher@gunnaire.com'")
        self.assertEqual(self.post(role="Dispatcher")[0], 404)
        self.assertEqual(self.get(role="Dispatcher")[0], 404)
        self.assertEqual(self.count(), 1)

    def test_all_pages_are_bounded_ordered_and_bound_to_one_immutable_original_index(self):
        status, receipt = self.seed(extra=175)
        self.assertEqual(status, 200, receipt)
        result, query = [], dict(self.scope)
        while True:
            status, page = self.get(records=True, query=query)
            self.assertEqual(status, 200, page)
            self.assertLessEqual(len(page["records"]), service.PAGE_SIZE)
            self.assertEqual(page["snapshotSHA256"], receipt["snapshotSHA256"])
            result.extend(page["records"])
            if page["nextCursor"] is None:
                break
            query["after"] = page["nextCursor"]
        keys = [(r["kind"], r["id"]) for r in result]
        self.assertEqual(keys, sorted(set(keys)))
        self.assertEqual(len(result), receipt["recordCount"])
        invalid = dict(self.scope, after="vendor:" + str(uuid.uuid4()))
        self.assertEqual(self.get(records=True, query=invalid)[1]["code"], "invalid_cursor")

    def test_typed_request_schema_unknown_fields_bool_revisions_and_foreign_scope_are_rejected(self):
        self.assertEqual(self.seed()[0], 200)
        for key, value in (("expectedSourceSequence", True), ("expectedShareRevision", True), ("sourceSchemaDigest", "0" * 64),
                           ("extraPermission", True), ("companyID", str(uuid.uuid4())), ("replicaID", str(uuid.uuid4())), ("environment", "production")):
            with self.subTest(key=key):
                self.assertNotEqual(self.post(dict(self.payload, operationID=str(uuid.uuid4()), **{key: value}))[0], 200)
        self.assertEqual(self.count(), 1)

    def test_current_membership_deactivation_blocks_receipts_and_pages(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (EMAIL,))
        self.assertEqual(self.get()[0], 403)
        self.assertEqual(self.get(records=True)[0], 403)
        self.assertEqual(self.post()[0], 403)
        self.assertEqual(self.count(), 1)

    def test_share_revocation_keeps_the_original_but_refuses_further_use(self):
        self.assertEqual(self.seed()[0], 200)
        self.advance(self.share, "revoke")
        self.assertEqual(self.get()[0], 403)
        self.assertEqual(self.get(records=True)[0], 403)
        self.assertEqual(self.post()[0], 403)
        self.assertEqual(self.count(), 1)

    def test_member_role_change_cannot_reuse_a_previous_role_index(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Accounting',updated_at=? WHERE email=?", (backend.utc_now(), EMAIL))
        self.assertEqual(self.get()[0], 403)
        self.assertEqual(self.post(dict(self.payload, operationID=str(uuid.uuid4())))[0], 403)
        self.assertEqual(self.count(), 1)

    def test_saved_policy_must_match_current_role_before_any_new_index_is_prepared(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE cloudkit_staff_shares SET projection_policy='admin-operations-v1' WHERE id=?", (self.share["id"],))
        self.assertEqual(self.post(dict(self.payload, operationID=str(uuid.uuid4())))[0], 403)
        self.assertEqual(self.get()[0], 403)
        self.assertEqual(self.count(), 1)

    def test_approver_demotion_blocks_new_selection_by_another_active_administrator(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Admin' WHERE email='dispatcher@gunnaire.com'")
            connection.execute("UPDATE users SET role='Standard' WHERE email='admin@gunnaire.com'")
        self.assertEqual(self.post(dict(self.payload, operationID=str(uuid.uuid4())), role="Dispatcher")[0], 403)
        self.assertEqual(self.count(), 1)

    def test_encryption_failure_rolls_back_new_selection_without_changing_source_or_original(self):
        self.assertEqual(self.seed()[0], 200)
        before = self.get()
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("fixture failure")):
            self.assertEqual(self.post(dict(self.payload, operationID=str(uuid.uuid4())))[0], 503)
        self.assertEqual(self.get(), before)
        self.assertEqual(self.count(), 1)

    def test_duplicate_queries_unknown_routes_and_forged_decrypted_shape_fail_closed(self):
        self.assertEqual(self.seed()[0], 200)
        path = self.endpoint + "/" + self.payload["operationID"] + "?" + urllib.parse.urlencode(self.scope) + "&companyID=" + self.company
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path)[0], 400)
        self.assertEqual(self.request(token=self.tokens["Admin"], path=self.endpoint + "/extra/path")[0], 404)
        with backend.db() as connection:
            saved = connection.execute("SELECT ciphertext FROM staff_workspace_selections").fetchone()[0]
            data = json.loads(backend.decrypt_catalog_payload(saved))
            data["snapshot"]["rawOwnerFields"] = {"private": "not permitted"}
            connection.execute("UPDATE staff_workspace_selections SET ciphertext=?", (backend.encrypt_catalog_payload(json.dumps(data)),))
        self.assertEqual(self.get()[0], 503)
        self.assertEqual(self.count(), 1)

    def test_session_revoked_between_http_check_and_transaction_blocks_selection_creation(self):
        self.assertEqual(self.seed()[0], 200)
        before = backend.GunnAireBackendHandler.require_application_session
        def revoke(handler):
            result = before(handler)
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE email='admin@gunnaire.com'", (backend.utc_now(),))
            return result
        with mock.patch.object(backend.GunnAireBackendHandler, "require_application_session", revoke):
            self.assertEqual(self.post(dict(self.payload, operationID=str(uuid.uuid4())))[0], 403)
        self.assertEqual(self.count(), 1)

    def test_ciphertext_failure_does_not_replace_or_rebuild_the_original_operation(self):
        self.assertEqual(self.seed()[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_workspace_selections SET ciphertext='unverifiable' WHERE id=?", (self.payload["operationID"],))
        self.assertEqual(self.get()[0], 503)
        self.assertEqual(self.get(records=True)[0], 503)
        self.assertEqual(self.post()[0], 503)
        self.assertEqual(self.count(), 1)


if __name__ == "__main__":
    unittest.main()
