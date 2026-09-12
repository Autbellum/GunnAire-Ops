from __future__ import annotations

import base64
import copy
import contextlib
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import urllib.parse
import urllib.request
import urllib.error
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from unittest import mock

from Backend import gunnaire_backend as backend, staff_replica as replica
from Backend import staff_replica_contract as contract
from Backend import test_cloudkit_staff_shares as sharing_fixture


class StaffReplicaTests(unittest.TestCase):
    SharingFixture = sharing_fixture.CloudKitStaffSharingTests
    setUp = SharingFixture.setUp
    tearDown = SharingFixture.tearDown
    request = SharingFixture.request
    workspace = SharingFixture.workspace
    binding_payload = SharingFixture.binding_payload
    bind = SharingFixture.bind
    prepare = SharingFixture.prepare
    enroll = SharingFixture.enroll
    read = SharingFixture.read
    change = SharingFixture.change
    requested = SharingFixture.requested
    advance = SharingFixture.advance
    accepted = SharingFixture.accepted
    root = SharingFixture.root
    participant_name = SharingFixture.participant_name
    participant_hash = SharingFixture.participant_hash
    source = "/api/workspace/replica-records"

    def identifier(self, number):
        return f"b1000000-0000-4000-8000-{number:012d}"

    def record(self, kind, number, fields, revision=0, action="upsert"):
        return {"kind": kind, "id": self.identifier(number), "fields": fields, "expectedRevision": revision, "action": action}

    def batch(self, changes, sequence=0, **values):
        return {"companyID": self.company, "environment": "development", "schema": contract.SCHEMA_VERSION,
                "operationID": str(uuid.uuid4()), "expectedSequence": sequence, "changes": changes, **values}

    def apply(self, payload, role="Admin"):
        return self.request(token=self.tokens[role], payload=payload, method="POST", path=self.source)

    def source_page(self, role="Admin", **values):
        query = {"companyID": self.company, "environment": "development", **values}
        return self.request(token=self.tokens[role], path=self.source + "?" + urllib.parse.urlencode(query))

    def prepare_projection(self, share, sequence=1, **values):
        payload = {"companyID": self.company, "environment": "development", "operationID": str(uuid.uuid4()),
                   "expectedSequence": sequence, "expectedShareRevision": share["revision"], **values}
        return self.request(token=self.tokens["Admin"], payload=payload, method="POST", path=self.root + "/" + share["id"] + "/projections"), payload

    def projection(self, share, operation, role="Admin", content=False, **values):
        query = {"companyID": self.company, "environment": "development", **values}
        return self.request(token=self.tokens[role], path=self.root + "/" + share["id"] + "/projections/" + operation +
                            ("/payload" if content else "") + "?" + urllib.parse.urlencode(query))

    def seed(self):
        i = self.identifier
        data = [
            self.record("customer", 1, {"name": "Authorized customer", "phone": "555-0100", "allowsServiceText": False}),
            self.record("customer", 2, {"name": "Unrelated customer secret"}),
            self.record("location", 10, {"customerID": i(1), "name": "Assigned property", "address": "10 Main", "isActive": True}),
            self.record("location", 11, {"customerID": i(1), "name": "Other property", "address": "11 Main", "isActive": True, "accessNotes": "Unrelated access code"}),
            self.record("equipment", 20, {"customerID": i(1), "serviceLocationID": i(10), "name": "Heat pump", "serialNumber": "SERIAL-ORIGINAL", "isActive": True}),
            self.record("equipment", 21, {"customerID": i(1), "serviceLocationID": i(11), "name": "Other property system", "isActive": True}),
            self.record("technician", 30, {"name": "Assigned tech", "email": "field.technician@gunnaire.com", "isActive": True}),
            self.record("technician", 31, {"name": "Crew member", "email": "crew@example.invalid", "isActive": True}),
            self.record("technician", 32, {"name": "Unrelated employee", "email": "unrelated@example.invalid", "isActive": True}),
            self.record("job", 40, {"customerID": i(1), "serviceLocationID": i(10), "customerEquipmentID": i(20), "type": "repair", "scheduledDate": "2026-09-09T10:00:00Z", "duration": 3600,
                                    "status": "scheduled", "assignedTechnicianIDs": [i(30), i(31)], "originatingServiceCallID": i(41)}),
            self.record("job", 41, {"customerID": i(2), "type": "replacement", "scheduledDate": "2026-09-09T12:00:00Z", "duration": 7200,
                                    "status": "scheduled", "assignedTechnicianIDs": [i(32)]}),
            self.record("item", 50, {"name": "Approved field service", "itemType": "service", "unitPrice": 125, "purchaseCost": 35, "isTaxable": False, "reviewStatus": "approved"}),
            self.record("item", 51, {"name": "Own field-created item", "itemType": "non_inventory", "unitPrice": 20, "isTaxable": True, "reviewStatus": "needs_review", "createdByEmail": "field.technician@gunnaire.com"}),
            self.record("item", 52, {"name": "Another worker draft", "itemType": "service", "unitPrice": 5, "isTaxable": False, "reviewStatus": "needs_review", "createdByEmail": "unrelated@example.invalid"}),
        ]
        payload = self.batch(data)
        status, result = self.apply(payload)
        self.assertEqual(status, 200, result)
        return payload

    def payload(self, share, sequence=1):
        (status, receipt), _ = self.prepare_projection(share, sequence)
        self.assertEqual(status, 200, receipt)
        status, content = self.projection(share, receipt["operationID"], content=True)
        self.assertEqual(status, 200, content)
        raw = base64.b64decode(content["payloadBase64"], validate=True)
        self.assertEqual(len(raw), receipt["payloadBytes"])
        self.assertEqual(hashlib.sha256(raw).hexdigest(), receipt["payloadSHA256"])
        return json.loads(raw), receipt

    def test_source_is_encrypted_and_lost_reply_replays_original_batch_once(self):
        self.prepare(); payload = self.seed()
        first = self.apply(payload)
        self.assertEqual(first[0], 200)
        backend.initialize_database()
        self.assertEqual(self.apply(payload), first)
        self.assertEqual(self.source_page()[1]["sequence"], 1)
        with backend.db() as connection:
            rows = connection.execute("SELECT * FROM staff_replica_records").fetchall()
            self.assertEqual(len(rows), 14)
            self.assertNotIn("Authorized customer", str([dict(row) for row in rows]))
            self.assertNotIn("SERIAL-ORIGINAL", str([dict(row) for row in rows]))
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_operations").fetchone()[0], 1)

    def test_source_upload_and_recovery_are_admin_only(self):
        self.prepare(); payload = self.batch([self.record("customer", 1, {"name": "A"})])
        for role in self.tokens:
            if role != "Admin":
                self.assertEqual(self.apply(payload, role)[0], 403)
                self.assertEqual(self.source_page(role)[0], 403)
        self.assertEqual(self.source_page()[1]["sequence"], 0)

    def test_batch_is_atomic_when_one_record_revision_conflicts(self):
        self.prepare(); self.seed()
        payload = self.batch([self.record("customer", 1, {"name": "Changed"}, 1), self.record("customer", 2, {"name": "Wrong"}, 3)], 1)
        self.assertEqual(self.apply(payload)[1]["code"], "record_changed")
        page = self.source_page()[1]
        self.assertEqual(page["sequence"], 1)
        self.assertEqual(page["records"][0]["fields"]["name"], "Authorized customer")

    def test_encrypt_or_audit_failure_retains_original_and_rolls_back_whole_batch(self):
        self.prepare(); payload = self.batch([self.record("customer", 1, {"name": "Do not lose"})])
        for name in ("encrypt_catalog_payload", "record_audit_event"):
            with mock.patch.object(backend, name, side_effect=RuntimeError("do not leak this")):
                status, result = self.apply(payload)
                self.assertEqual(status, 503)
                self.assertNotIn("do not leak", json.dumps(result))
            self.assertEqual(self.source_page()[1]["sequence"], 0)
        self.assertEqual(self.apply(payload)[0], 200)

    def test_same_operation_race_has_one_durable_sequence_and_different_batch_conflicts(self):
        self.prepare(); payload = self.batch([self.record("customer", 1, {"name": "Original"})])
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.apply(payload), range(4)))
        self.assertTrue(all(result == results[0] and result[0] == 200 for result in results))
        self.assertEqual(self.apply({**payload, "operationID": str(uuid.uuid4())})[1]["code"], "source_changed")

    def test_changed_replay_scope_or_body_cannot_replace_original(self):
        self.prepare(); payload = self.seed()
        changed = copy.deepcopy(payload); changed["changes"][0]["fields"]["name"] = "Replacement"
        self.assertEqual(self.apply(changed)[1]["code"], "operation_changed")
        self.assertEqual(self.apply({**payload, "companyID": str(uuid.uuid4())})[0], 403)
        self.assertEqual(self.apply({**payload, "environment": "production"})[1]["code"], "owner_required")
        self.assertEqual(self.source_page()[1]["sequence"], 1)

    def test_invalid_or_unlisted_fields_types_and_noncanonical_ids_are_rejected(self):
        self.prepare()
        invalid = [self.record("customer", 1, {"name": "A", "storedPaymentMethodsJSON": "secret"}),
                   self.record("customer", 1, {"name": "A", "allowsServiceText": 1}),
                   self.record("technician", 1, {"name": "T", "email": "Mixed@example.invalid", "isActive": True}),
                   self.record("job", 1, {}), self.record("invoice", 1, {"name": "Not covered"}),
                   self.record("item", 1, {"name": "X", "itemType": "service", "unitPrice": True, "isTaxable": False, "reviewStatus": "approved"})]
        for change in invalid:
            self.assertEqual(self.apply(self.batch([change]))[0], 400)
        for value in (True, -1, "0", 0.0):
            self.assertEqual(self.apply(self.batch([self.record("customer", 1, {"name": "A"})], value))[0], 400)
        self.assertEqual(self.source_page()[1]["records"], [])

    def test_duplicate_record_in_batch_cannot_mask_an_overwrite(self):
        self.prepare(); record = self.record("customer", 1, {"name": "Original"})
        self.assertEqual(self.apply(self.batch([record, record]))[1]["code"], "duplicate_record")

    def test_source_pagination_pins_complete_sequence_and_restarts_on_changes(self):
        self.prepare()
        self.assertEqual(self.apply(self.batch([self.record("customer", n, {"name": f"C{n}"}) for n in range(1, 101)]))[0], 200)
        self.assertEqual(self.apply(self.batch([self.record("customer", 101, {"name": "C101"})], 1))[0], 200)
        page = self.source_page()[1]
        self.assertEqual(len(page["records"]), 100)
        last = self.source_page(sequence=2, after=page["nextCursor"])[1]
        self.assertEqual([r["id"] for r in last["records"]], [self.identifier(101)])
        self.assertIsNone(last["nextCursor"])
        self.assertEqual(self.apply(self.batch([self.record("customer", 102, {"name": "C102"})], 2))[0], 200)
        self.assertEqual(self.source_page(sequence=2, after=page["nextCursor"])[1]["code"], "source_changed")
        self.assertEqual(self.source_page(after=page["nextCursor"])[0], 400)

    def test_deletions_are_retained_and_only_explicit_restore_can_revive(self):
        self.prepare(); self.seed()
        delete = self.batch([self.record("item", 50, {}, 1, "delete")], 1)
        self.assertEqual(self.apply(delete)[0], 200)
        value = next(r for r in self.source_page()[1]["records"] if r["id"] == self.identifier(50))
        self.assertTrue(value["deleted"]); self.assertEqual(value["fields"]["unitPrice"], 125)
        restore = self.batch([self.record("item", 50, value["fields"], 2)], 2)
        self.assertEqual(self.apply(restore)[1]["code"], "deletion_changed")
        restore["changes"][0]["action"] = "restore"
        self.assertEqual(self.apply(restore)[0], 200)
        self.assertEqual(self.apply(delete)[1]["sequence"], 2)
        self.assertEqual(self.apply(delete)[1]["currentSequence"], 3)

    def test_field_projection_contains_only_assigned_property_equipment_crew_and_pricebook(self):
        self.prepare(); share = self.accepted(); self.seed()
        value, receipt = self.payload(share)
        ids = {record["id"] for record in value["records"]}
        self.assertEqual(ids, {self.identifier(n) for n in (1, 10, 20, 30, 31, 40, 50, 51)})
        text = json.dumps(value)
        for excluded in ("Unrelated", "Other property", "Another worker", "purchaseCost", "originatingServiceCallID"):
            self.assertNotIn(excluded, text)
        self.assertTrue(value["completeForSchema"])
        self.assertEqual(value["coverage"], contract.COVERAGE)
        self.assertFalse(receipt["operationalWorkspaceReady"])
        self.assertTrue(receipt["localCloudKitProofRequired"])

    def test_dispatcher_has_operational_scope_without_cost_and_standard_has_no_implicit_grant(self):
        self.prepare(); self.seed()
        for role, count in (("Dispatcher", 14), ("Standard", 0), ("Accounting", 0), ("Admin", 14)):
            share = self.accepted(role)
            value, _ = self.payload(share)
            self.assertEqual(len(value["records"]), count)
            if role != "Admin":
                self.assertNotIn("purchaseCost", json.dumps(value))

    def test_staff_receives_authority_only_and_cannot_download_business_data_via_backend(self):
        self.prepare(); share = self.accepted(); self.seed()
        _, receipt = self.payload(share)
        status, result = self.projection(share, receipt["operationID"], "Field Technician")
        self.assertEqual(status, 200)
        self.assertNotIn("payloadBase64", result)
        self.assertEqual(self.projection(share, receipt["operationID"], "Field Technician", content=True)[0], 403)
        self.assertEqual(self.projection(share, receipt["operationID"], "Dispatcher")[0], 404)

    def test_original_projection_replays_exact_identity_and_payload_after_restart(self):
        self.prepare(); share = self.accepted(); self.seed()
        (status, receipt), payload = self.prepare_projection(share)
        self.assertEqual(status, 200)
        before = self.projection(share, receipt["operationID"], content=True)
        backend.initialize_database()
        self.assertEqual(self.prepare_projection(share, operationID=payload["operationID"])[0], (200, receipt))
        self.assertEqual(self.projection(share, receipt["operationID"], content=True), before)
        self.assertEqual(self.prepare_projection(share, operationID=payload["operationID"], expectedSequence=0)[0][1]["code"], "operation_changed")

    def test_database_backup_restores_original_source_receipt_and_encrypted_projection(self):
        self.prepare(); share = self.accepted(); source = self.seed(); _, receipt = self.payload(share)
        before = self.projection(share, receipt["operationID"], content=True)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "restored.sqlite3"
            target = sqlite3.connect(path)
            try:
                with backend.db() as connection:
                    connection.backup(target)
            finally:
                target.close()
            with mock.patch.object(backend, "DB_PATH", path):
                backend.initialize_database()
                self.assertEqual(self.apply(source)[1]["sequence"], 1)
                self.assertEqual(self.projection(share, receipt["operationID"], content=True), before)

    def test_reassignment_invalidates_old_payload_and_next_full_snapshot_removes_prior_job(self):
        self.prepare(); share = self.accepted(); payload = self.seed()
        _, original = self.payload(share)
        job = copy.deepcopy(next(v for v in payload["changes"] if v["id"] == self.identifier(40)))
        job["expectedRevision"] = 1; job["fields"]["assignedTechnicianIDs"] = [self.identifier(31)]
        self.assertEqual(self.apply(self.batch([job], 1))[0], 200)
        self.assertFalse(self.projection(share, original["operationID"], "Field Technician")[1]["isCurrent"])
        self.assertEqual(self.projection(share, original["operationID"], content=True)[1]["code"], "source_changed")
        value, newer = self.payload(share, 2)
        self.assertNotIn("job", [row["kind"] for row in value["records"]])
        self.assertNotIn("customer", [row["kind"] for row in value["records"]])
        self.assertNotEqual(original["payloadSHA256"], newer["payloadSHA256"])

    def test_ordinary_content_update_does_not_starve_an_authorized_inflight_snapshot(self):
        self.prepare(); share = self.accepted(); source = self.seed(); _, receipt = self.payload(share)
        customer = copy.deepcopy(source["changes"][0]); customer["expectedRevision"] = 1; customer["fields"]["phone"] = "555-0123"
        self.assertEqual(self.apply(self.batch([customer], 1))[0], 200)
        status, retained = self.projection(share, receipt["operationID"], content=True)
        self.assertEqual(status, 200)
        self.assertFalse(retained["isCurrent"])
        self.assertTrue(retained["authorizationCurrent"])
        self.assertEqual(retained["sourceSequence"], 1)
        self.assertEqual(retained["currentSequence"], 2)
        # An old snapshot remains explicitly old; it can never advance the
        # native importer's checkpoint to currentSequence or overwrite newer data.
        self.assertEqual(json.loads(base64.b64decode(retained["payloadBase64"]))["sourceSequence"], 1)

    def test_reassigning_away_then_back_never_reauthorizes_an_old_export(self):
        self.prepare(); share = self.accepted(); payload = self.seed(); _, receipt = self.payload(share)
        job = copy.deepcopy(next(v for v in payload["changes"] if v["id"] == self.identifier(40)))
        original_crew = job["fields"]["assignedTechnicianIDs"]
        job["expectedRevision"] = 1; job["fields"]["assignedTechnicianIDs"] = [self.identifier(31)]
        self.assertEqual(self.apply(self.batch([job], 1))[0], 200)
        job["expectedRevision"] = 2; job["fields"]["assignedTechnicianIDs"] = original_crew
        self.assertEqual(self.apply(self.batch([job], 2))[0], 200)
        self.assertFalse(self.projection(share, receipt["operationID"], "Field Technician")[1]["authorizationCurrent"])
        self.assertEqual(self.projection(share, receipt["operationID"], content=True)[0], 409)

    def test_legacy_payload_cannot_acquire_new_authorization_evidence_during_migration(self):
        self.prepare(); share = self.accepted(); self.seed(); _, receipt = self.payload(share)
        with backend.db() as connection:
            connection.execute("UPDATE staff_replica_heads SET authorization_sequence=0")
            connection.execute("UPDATE staff_replica_projections SET authorization_sequence=0")
        backend.initialize_database()
        self.assertFalse(self.projection(share, receipt["operationID"], "Field Technician")[1]["authorizationCurrent"])
        self.assertEqual(self.projection(share, receipt["operationID"], content=True)[0], 409)
        self.assertEqual(len(self.source_page()[1]["records"]), 14)
        _, newer = self.payload(share)
        self.assertTrue(newer["authorizationCurrent"])

    def test_dangling_or_wrong_customer_links_never_become_partial_success(self):
        self.prepare(); share = self.accepted(); payload = self.seed()
        job = copy.deepcopy(next(v for v in payload["changes"] if v["kind"] == "job"))
        job["expectedRevision"] = 1; job["fields"]["serviceLocationID"] = self.identifier(999)
        self.assertEqual(self.apply(self.batch([job], 1))[0], 200)
        self.assertEqual(self.prepare_projection(share, 2)[0][1]["code"], "relationships_pending")
        job["expectedRevision"] = 2; job["fields"]["serviceLocationID"] = self.identifier(10); job["fields"]["customerID"] = self.identifier(2)
        self.assertEqual(self.apply(self.batch([job], 2))[0], 200)
        self.assertEqual(self.prepare_projection(share, 3)[0][1]["code"], "relationships_changed")

    def test_duplicate_technician_identity_does_not_broaden_field_assignments(self):
        self.prepare(); share = self.accepted(); self.seed()
        value = self.record("technician", 33, {"name": "Duplicate", "email": "field.technician@gunnaire.com", "isActive": True})
        self.assertEqual(self.apply(self.batch([value], 1))[0], 200)
        self.assertEqual(self.prepare_projection(share, 2)[0][1]["code"], "identity_ambiguous")

    def test_missing_technician_mapping_is_not_a_successful_empty_work_list(self):
        self.prepare(); share = self.accepted()
        self.assertEqual(self.apply(self.batch([self.record("customer", 1, {"name": "Original"})]))[0], 200)
        self.assertEqual(self.prepare_projection(share)[0][1]["code"], "identity_pending")

    def test_job_and_equipment_cannot_silently_cross_properties_of_same_customer(self):
        self.prepare(); share = self.accepted(); payload = self.seed()
        job = copy.deepcopy(next(v for v in payload["changes"] if v["id"] == self.identifier(40)))
        job["expectedRevision"] = 1; job["fields"]["customerEquipmentID"] = self.identifier(21)
        self.assertEqual(self.apply(self.batch([job], 1))[0], 200)
        self.assertEqual(self.prepare_projection(share, 2)[0][1]["code"], "relationships_changed")

    def test_legacy_job_without_property_can_follow_its_exact_equipment_property(self):
        self.prepare(); share = self.accepted(); payload = self.seed()
        job = copy.deepcopy(next(v for v in payload["changes"] if v["id"] == self.identifier(40)))
        job["expectedRevision"] = 1; job["fields"].pop("serviceLocationID")
        self.assertEqual(self.apply(self.batch([job], 1))[0], 200)
        value, _ = self.payload(share, 2)
        locations = [row["id"] for row in value["records"] if row["kind"] == "location"]
        self.assertEqual(locations, [self.identifier(10)])

    def test_corrupt_original_batch_receipt_does_not_reapply_source(self):
        self.prepare(); payload = self.seed()
        with backend.db() as connection:
            connection.execute("UPDATE staff_replica_operations SET receipt='broken'")
        self.assertEqual(self.apply(payload)[0], 503)
        self.assertEqual(self.source_page()[1]["sequence"], 1)

    def test_environment_scoped_ledgers_keep_same_local_record_ids_separate(self):
        self.prepare(); self.seed()
        production = self.binding_payload(environment="production", cloudAccountHash="d" * 64)
        self.assertEqual(self.bind(production)[0], 201)
        payload = self.batch([self.record("customer", 1, {"name": "Production only"})], environment="production")
        self.assertEqual(self.apply(payload)[0], 200)
        self.assertEqual(self.source_page(environment="production")[1]["records"][0]["fields"]["name"], "Production only")
        self.assertEqual(self.source_page()[1]["records"][0]["fields"]["name"], "Authorized customer")

    def test_changed_approver_revision_stops_data_export_without_erasing_original(self):
        self.prepare(); share = self.accepted(); self.seed(); _, receipt = self.payload(share)
        with backend.db() as connection:
            connection.execute("UPDATE users SET updated_at=? WHERE email='admin@gunnaire.com'", ((datetime.now(timezone.utc) + timedelta(seconds=1)).isoformat(),))
        self.assertEqual(self.projection(share, receipt["operationID"], content=True)[0], 403)
        self.assertEqual(self.projection(share, receipt["operationID"], "Field Technician")[0], 403)

    def test_role_or_business_revocation_blocks_original_projection_reads(self):
        self.prepare(); share = self.accepted(); self.seed(); _, receipt = self.payload(share)
        self.advance(share, "revoke")
        for content in (False, True):
            self.assertEqual(self.projection(share, receipt["operationID"], content=content)[0], 403)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_projections").fetchone()[0], 1)

    def test_member_role_revision_change_blocks_read_even_with_same_email(self):
        self.prepare(); share = self.accepted(); self.seed(); _, receipt = self.payload(share)
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard',updated_at=? WHERE email='field.technician@gunnaire.com'", (backend.utc_now(),))
        self.assertEqual(self.projection(share, receipt["operationID"], "Field Technician")[0], 403)

    def test_session_revoked_after_http_check_cannot_publish_source(self):
        self.prepare(); payload = self.batch([self.record("customer", 1, {"name": "Original"})])
        original = backend.GunnAireBackendHandler.require_application_session
        def revoke(handler):
            result = original(handler)
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE email='admin@gunnaire.com'", (backend.utc_now(),))
            return result
        with mock.patch.object(backend.GunnAireBackendHandler, "require_application_session", revoke):
            self.assertEqual(self.apply(payload)[0], 403)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_records").fetchone()[0], 0)

    def test_corrupt_encrypted_record_is_retained_not_overwritten_or_exported(self):
        self.prepare(); share = self.accepted(); self.seed()
        with backend.db() as connection:
            connection.execute("UPDATE staff_replica_records SET ciphertext='corrupt' WHERE record_id=?", (self.identifier(1),))
        self.assertEqual(self.source_page()[0], 503)
        self.assertEqual(self.apply(self.batch([self.record("customer", 1, {"name": "Replacement"}, 1)], 1))[0], 503)
        self.assertEqual(self.prepare_projection(share)[0][0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT ciphertext FROM staff_replica_records WHERE record_id=?", (self.identifier(1),)).fetchone()[0], "corrupt")

    def test_copied_ciphertext_cannot_substitute_another_record_or_projection(self):
        self.prepare(); share = self.accepted(); self.seed(); _, receipt = self.payload(share)
        with backend.db() as connection:
            row = connection.execute("SELECT ciphertext FROM staff_replica_records WHERE record_id=?", (self.identifier(2),)).fetchone()
            connection.execute("UPDATE staff_replica_records SET ciphertext=? WHERE record_id=?", (row[0], self.identifier(1)))
            connection.execute("UPDATE staff_replica_projections SET ciphertext=?", (row[0],))
        self.assertEqual(self.source_page()[0], 503)
        self.assertEqual(self.projection(share, receipt["operationID"], content=True)[0], 503)

    def test_projection_audit_failure_does_not_leave_a_publishable_receipt(self):
        self.prepare(); share = self.accepted(); self.seed()
        with mock.patch.object(backend, "record_audit_event", side_effect=RuntimeError()):
            self.assertEqual(self.prepare_projection(share)[0][0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_projections").fetchone()[0], 0)

    def test_snapshot_limits_fail_without_truncation_or_false_empty_workspace(self):
        self.prepare(); share = self.accepted(); self.seed()
        for name, limit in (("MAX_RECORDS", 1), ("MAX_SNAPSHOT_BYTES", 1), ("MAX_SOURCE_SCAN_BYTES", 1)):
            with mock.patch.object(replica, name, limit):
                self.assertEqual(self.prepare_projection(share)[0][1]["code"], "snapshot_too_large")
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_replica_projections").fetchone()[0], 0)

    def test_http_log_redacts_company_and_source_cursor_identifiers(self):
        handler = backend.GunnAireBackendHandler.__new__(backend.GunnAireBackendHandler)
        handler.client_address = ("127.0.0.1", 1234)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            handler.log_message('%s', 'GET /api/workspace/replica-records?companyID=private-company&after=customer:private-record HTTP/1.1')
        self.assertIn("/api/workspace/replica-records/[redacted]", output.getvalue())
        self.assertNotIn("private-company", output.getvalue()); self.assertNotIn("private-record", output.getvalue())

    def test_projection_requires_source_and_accepted_current_invitation(self):
        self.prepare(); share = self.accepted()
        self.assertEqual(self.prepare_projection(share, 0)[0][1]["code"], "source_pending")
        self.seed()
        self.assertEqual(self.prepare_projection(share, 0)[0][1]["code"], "source_changed")
        self.assertEqual(self.prepare_projection(share, expectedShareRevision=3)[0][1]["code"], "source_changed")
        requested = self.requested("Dispatcher")
        self.assertEqual(self.prepare_projection(requested)[0][0], 403)

    def test_routine_source_sync_does_not_require_reapproving_share_every_ten_minutes(self):
        self.prepare(); share = self.accepted()
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at=? WHERE email='admin@gunnaire.com'", ((datetime.now(timezone.utc) - timedelta(hours=1)).isoformat(),))
        self.seed()
        self.assertEqual(self.prepare_projection(share)[0][0], 200)
        self.assertEqual(self.change(share, "revoke")[0][0], 403)

    def test_http_rejects_duplicate_fields_nonfinite_json_unknown_queries_and_unsafe_paths(self):
        self.prepare()
        for raw in ('{"companyID":"one","companyID":"two"}', '{"amount":NaN}', '[' * 1500 + ']' * 1500):
            request = urllib.request.Request(self.base_url + self.source, data=raw.encode(), method="POST",
                                             headers={"Authorization": "Bearer " + self.tokens["Admin"], "Content-Type": "application/json"})
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request)
            self.assertEqual(caught.exception.code, 400)
        self.assertEqual(self.source_page(extra="unknown")[0], 400)
        self.assertEqual(self.source_page(sequence="00")[0], 409)
        path = self.source + "?" + urllib.parse.urlencode({"companyID": self.company, "environment": "development"}) + "&environment=development"
        self.assertEqual(self.request(token=self.tokens["Admin"], path=path)[0], 400)
        self.assertEqual(self.request(token=self.tokens["Admin"], path=self.source + "/remove", method="POST", payload={})[0], 404)


if __name__ == "__main__":
    unittest.main()
