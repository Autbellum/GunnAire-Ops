import json
import sqlite3
import unittest
import uuid
from datetime import datetime, timezone
from unittest import mock

from Backend import gunnaire_backend as backend, staff_owner_field_handoffs as handoffs
from Backend import test_staff_owner_field_edits as edits


class OwnerFieldHandoffHTTPTests(unittest.TestCase):
    def setUp(self):
        self.f = edits.OwnerFieldEditHTTPTests()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.prepare = self.f.prepare_body()
        status, self.claim = self.f.post("prepare", self.prepare)
        self.assertEqual(status, 200)
        self.body = dict(**self.f.f.scope, schema=handoffs.SCHEMA, commandID=self.f.id,
            operationID=str(uuid.uuid4()), ownerStoreID=self.f.owner_store, claimOperationID=self.prepare["operationID"],
            expectedRevision=self.prepare["expectedRevision"], expectedValue=self.prepare["expectedValue"], writeFence="before-save-v1")

    def release(self, body=None, role="Admin"):
        return self.f.post("release", self.body if body is None else body, role)

    def test_release_preserves_original_and_another_store_can_complete_same_command(self):
        status, receipt = self.release()
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["outcome"], "released")
        self.assertIsNone(self.f.get(self.f.id)[1]["application"])
        self.assertEqual(self.f.get(self.f.id)[1]["receipt"], self.f.receipt)
        next_claim = dict(self.prepare, operationID=str(uuid.uuid4()), ownerStoreID=str(uuid.uuid4()))
        self.assertEqual(self.f.post("prepare", next_claim)[0], 200)
        self.assertEqual(self.release(), (200, receipt))  # Lost release reply after another store claims.
        self.f.advance_job(self.f.command["value"]["text"]["_0"])
        self.assertEqual(self.f.post("confirm", self.f.confirm_body(next_claim))[1]["state"], "published")
        self.assertEqual(self.release(), (200, receipt))
        with backend.db() as connection:
            row = connection.execute("SELECT * FROM staff_owner_field_handoffs").fetchone()
            archived = json.loads(backend.decrypt_catalog_payload(row["ciphertext"]))
            self.assertEqual(archived["application"], dict(request=self.prepare, receipt=self.claim))
            self.assertNotIn(json.dumps(self.prepare["expectedValue"]), row["ciphertext"])
            for action in ("UPDATE staff_owner_field_handoffs SET owner_email='changed@example.invalid'", "DELETE FROM staff_owner_field_handoffs"):
                with self.assertRaises(sqlite3.IntegrityError): connection.execute(action)

    def test_released_store_cannot_reclaim_confirm_or_close_original(self):
        self.assertEqual(self.release()[0], 200)
        for body in (self.prepare, dict(self.prepare, operationID=str(uuid.uuid4()))):
            self.assertEqual(self.f.post("prepare", body)[1]["code"], "edit_released")
        self.assertEqual(self.f.post("confirm", self.f.confirm_body(self.prepare))[1]["code"], "edit_released")
        kept = dict(self.body, schema="staff-owner-field-resolution-v1", operationID=str(uuid.uuid4()), claimOperationID="")
        kept.pop("writeFence")
        self.assertEqual(self.f.post("keep-office", kept)[1]["code"], "edit_released")

    def test_only_original_account_store_claim_and_exact_unapplied_value_release(self):
        for changes in ({"ownerStoreID": str(uuid.uuid4())}, {"claimOperationID": str(uuid.uuid4())},
                        {"expectedRevision": 99}, {"expectedValue": {"text": {"_0": "Changed review"}}}):
            self.assertEqual(self.release(dict(self.body, **changes))[0], 409)
            self.assertEqual(self.f.get(self.f.id)[1]["application"], self.claim)
        for role in ("Field Technician", "Dispatcher", "Accounting", "Standard"):
            self.assertEqual(self.release(role=role)[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Technician' WHERE email=?", (self.claim["ownerEmail"],))
        self.assertEqual(self.release()[0], 403)

    def test_same_identity_cannot_change_release_request(self):
        self.assertEqual(self.release()[0], 200)
        self.assertEqual(self.release(dict(self.body, expectedRevision=2))[0], 409)
        self.assertEqual(self.release(dict(self.body, operationID=str(uuid.uuid4())))[1]["code"], "edit_released")

    def test_source_publication_and_third_value_reject_release(self):
        self.f.advance_job(self.f.command["value"]["text"]["_0"])
        self.assertEqual(self.release()[1]["code"], "field_changed")
        self.assertEqual(self.f.post("confirm", self.f.confirm_body(self.prepare))[0], 200)
        self.assertEqual(self.release()[1]["code"], "edit_claimed")

    def test_changed_source_revision_requires_new_review(self):
        self.f.advance_job("A newer office choice")
        self.assertEqual(self.release()[1]["code"], "field_changed")
        self.assertEqual(self.f.get(self.f.id)[1]["application"], self.claim)

    def test_closed_request_and_exact_paths(self):
        for changes in ({"unexpected": True}, {"writeFence": "trust-me"}, {"expectedRevision": True},
                        {"operationID": self.body["claimOperationID"]}):
            self.assertEqual(self.release(dict(self.body, **changes))[0], 400)
        missing = dict(self.body); missing.pop("writeFence")
        self.assertEqual(self.release(missing)[0], 400)
        for suffix in ("/release/", "/release?extra=1", "/release/extra"):
            status, _ = self.f.f.request(token=self.f.f.tokens["Admin"], path=self.f.root + "/" + self.f.id + suffix,
                method="POST", payload=self.body)
            self.assertEqual(status, 400)

    def test_encryption_and_clock_failures_keep_claim_and_archive_atomic(self):
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("fixture")):
            self.assertEqual(self.release()[0], 503)
        service_type = backend.staff_owner_field_edits.StaffOwnerFieldEdits
        def backwards_clock(shares):
            service = service_type(shares)
            authorize = service.source.scope
            def scope(*args):
                result = authorize(*args)
                shares.now = lambda: datetime(2000, 1, 1, tzinfo=timezone.utc)
                return result
            service.source.scope = scope
            return service
        with mock.patch.object(backend.staff_owner_field_edits, "StaffOwnerFieldEdits", side_effect=backwards_clock):
            self.assertEqual(self.release()[0], 503)
        self.assertEqual(self.f.get(self.f.id)[1]["application"], self.claim)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM staff_owner_field_handoffs").fetchone()[0], 0)
        self.assertEqual(self.release()[0], 200)

    def test_released_claim_operation_id_cannot_be_recycled(self):
        self.assertEqual(self.release()[0], 200)
        for operation in (self.prepare["operationID"], self.body["operationID"]):
            body = dict(self.prepare, ownerStoreID=str(uuid.uuid4()), operationID=operation)
            self.assertEqual(self.f.post("prepare", body)[1]["code"], "edit_claimed")

    def test_corrupt_archived_receipt_cannot_enable_retry_or_reclaim(self):
        self.assertEqual(self.release()[0], 200)
        with backend.db() as connection:
            connection.execute("DROP TRIGGER staff_owner_field_handoffs_no_update")  # Isolated test database only.
            connection.execute("UPDATE staff_owner_field_handoffs SET ciphertext='broken'")
        self.assertEqual(self.release()[0], 503)
        self.assertEqual(self.f.post("prepare", dict(self.prepare, operationID=str(uuid.uuid4())))[0], 503)
        self.assertEqual(self.f.post("prepare", dict(self.prepare, operationID=str(uuid.uuid4()), ownerStoreID=str(uuid.uuid4())))[0], 503)


if __name__ == "__main__": unittest.main()
