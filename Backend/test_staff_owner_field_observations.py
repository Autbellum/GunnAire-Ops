import copy
import json
import unittest
import uuid
from datetime import datetime, timezone
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import staff_owner_field_observations as observations
from Backend import test_staff_owner_field_edits as edit_tests


class OwnerFieldObservationHTTPTests(unittest.TestCase):
    def setUp(self):
        self.f = edit_tests.OwnerFieldEditHTTPTests()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.prepare = self.f.prepare_body()
        status, self.claim = self.f.post("prepare", self.prepare)
        self.assertEqual(status, 200)

    def body(self):
        current = self.f.get(self.f.id)[1]["current"]
        return dict(**self.f.f.scope, schema=observations.SCHEMA, commandID=self.f.id,
                    operationID=str(uuid.uuid4()), observerStoreID=str(uuid.uuid4()),
                    claimOperationID=self.claim["operationID"], expectedRevision=current["revision"],
                    expectedValue=copy.deepcopy(self.f.command["value"]))

    def publish(self):
        self.f.advance_job(self.f.command["value"]["text"]["_0"])
        return self.body()

    def post(self, body, role="Admin"):
        return self.f.post("confirm-observed", body, role)

    def test_existing_source_value_confirmed_without_transferring_claim(self):
        body = self.publish()
        before = self.f.get(self.f.id)[1]
        status, receipt = self.post(body)
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["request"], body)
        published = receipt["application"]
        self.assertEqual(dict(published, state="prepared", publishedAt=None), self.claim)
        after = self.f.get(self.f.id)[1]
        for field in ("request", "receipt", "baseValue", "current", "sourceSequence"):
            self.assertEqual(after[field], before[field])
        self.assertEqual(self.f.post("confirm", self.f.confirm_body(self.prepare)), (200, published))
        self.assertEqual(self.f.get()[1]["commandIDs"], [])

    def test_exact_retry_survives_later_office_revision(self):
        body = self.publish()
        first = self.post(body)
        from Backend.test_staff_workspace_commands import content_http
        job = content_http.fixtures.row(self.f.f.records, "job")
        content_http.fixtures.set_value(job, "notes", "Later office correction")
        self.f.f.write_source([job], 2, 2)
        backend.initialize_database()
        self.assertEqual(self.post(body), first)
        self.assertEqual(self.post(dict(body, operationID=str(uuid.uuid4())))[0], 409)

    def test_does_not_apply_or_take_over_an_unpublished_value(self):
        self.assertEqual(self.post(self.body())[1]["code"], "field_changed")
        self.assertEqual(self.f.get(self.f.id)[1]["application"], self.claim)

    def test_same_store_other_claim_and_changed_review_are_denied(self):
        body = self.publish()
        for change in ({"observerStoreID": self.claim["ownerStoreID"]},
                       {"claimOperationID": str(uuid.uuid4())}, {"expectedRevision": 1},
                       {"expectedValue": {"text": {"_0": "Unreviewed replacement"}}}):
            self.assertEqual(self.post(dict(body, **change))[0], 409)
        self.assertEqual(self.f.get(self.f.id)[1]["application"], self.claim)

    def test_strict_contract_and_current_authority_on_retries(self):
        body = self.publish()
        for change in ({"observerStoreID": "bad"}, {"expectedRevision": True}, {"unknown": 1},
                       {"expectedValue": {"flag": {"_0": True}}}, {"schema": "wrong"}):
            self.assertEqual(self.post(dict(body, **change))[0], 400)
        for role in ("Field Technician", "Dispatcher", "Accounting", "Standard"):
            self.assertEqual(self.post(body, role)[0], 403)
        self.assertEqual(self.post(body)[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (self.claim["ownerEmail"],))
        self.assertIn(self.post(body)[0], (401, 403))

    def test_confirmation_survives_original_staff_revocation(self):
        body = self.publish()
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (self.f.receipt["actorEmail"],))
        self.assertFalse(self.f.get(self.f.id)[1]["eligible"])
        self.assertEqual(self.post(body)[0], 200)

    def test_operation_cannot_be_reused_with_changed_request(self):
        body = self.publish()
        first = self.post(body)
        for change in ({"observerStoreID": str(uuid.uuid4())}, {"expectedRevision": 3}):
            self.assertEqual(self.post(dict(body, **change))[1]["code"], "observation_changed")
        self.assertEqual(self.post(body), first)

    def test_encryption_failure_leaves_both_tables_unchanged(self):
        body = self.publish()
        encrypt = backend.encrypt_catalog_payload
        for fail_at in (1, 2):
            count = [0]
            def failing(value):
                count[0] += 1
                if count[0] == fail_at:
                    raise RuntimeError("fixture encryption failure")
                return encrypt(value)
            with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=failing):
                self.assertEqual(self.post(body)[0], 503)
            self.assertEqual(self.f.get(self.f.id)[1]["application"], self.claim)
            with backend.db() as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_owner_field_observations").fetchone()[0], 0)
        self.assertEqual(self.post(body)[0], 200)

    def test_corrupt_witness_or_index_is_retained_and_fails_closed(self):
        body = self.publish()
        self.assertEqual(self.post(body)[0], 200)
        with backend.db() as connection:
            original = dict(connection.execute("SELECT * FROM staff_owner_field_observations").fetchone())
        for field, value in (("ciphertext", "broken"), ("observer_store_id", str(uuid.uuid4())),
                             ("observer_email", "different@example.invalid")):
            with backend.db() as connection:
                connection.execute("UPDATE staff_owner_field_observations SET " + field + "=?", (value,))
            self.assertEqual(self.post(body)[0], 503)
            with backend.db() as connection:
                self.assertEqual(connection.execute("SELECT " + field + " FROM staff_owner_field_observations").fetchone()[0], value)
                connection.execute("UPDATE staff_owner_field_observations SET " + field + "=?", (original[field],))

    def test_already_confirmed_original_preserves_publication_timestamp(self):
        body = self.publish()
        original = self.f.post("confirm", self.f.confirm_body(self.prepare))[1]
        status, receipt = self.post(body)
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["application"], original)

    def test_a_valid_but_different_owner_claim_is_not_confirmed(self):
        body = self.publish()
        with backend.db() as connection:
            row = connection.execute("SELECT ciphertext FROM staff_owner_field_edit_applications").fetchone()
            application = json.loads(backend.decrypt_catalog_payload(row[0]))
            application["receipt"]["ownerEmail"] = "another-owner@example.invalid"
            connection.execute("UPDATE staff_owner_field_edit_applications SET owner_email=?,ciphertext=?",
                ("another-owner@example.invalid", backend.encrypt_catalog_payload(json.dumps(application))))
        self.assertEqual(self.post(body)[1]["code"], "edit_claimed")

    def test_wrong_tenant_scope_cannot_confirm_or_read_a_witness(self):
        body = self.publish()
        for key in ("companyID", "replicaID"):
            self.assertIn(self.post(dict(body, **{key: str(uuid.uuid4())}))[0], (400, 403, 409))
        self.assertEqual(self.f.get(self.f.id)[1]["application"], self.claim)

    def test_keep_office_resolution_cannot_be_reopened_by_observation(self):
        from Backend import staff_owner_field_resolutions as resolutions
        keep = dict(**self.f.f.scope, schema=resolutions.SCHEMA, commandID=self.f.id,
            operationID=str(uuid.uuid4()), ownerStoreID=self.claim["ownerStoreID"], claimOperationID=self.claim["operationID"],
            expectedRevision=1, expectedValue=self.claim["expectedValue"])
        self.assertEqual(self.f.post("keep-office", keep)[0], 200)
        body = self.publish()
        self.assertEqual(self.post(body)[1]["code"], "edit_resolved")

    def test_clock_regression_never_persists_invalid_prepare_or_confirmation(self):
        second = self.f.f.command_body()
        self.assertEqual(self.f.f.submit(body=second)[0], 200)
        body = self.publish()
        detail = edit_tests.edits.StaffOwnerFieldEdits.detail
        def regressed(service, *args, **kwargs):
            value = detail(service, *args, **kwargs)
            service.shares.now = lambda: datetime(1970, 1, 1, tzinfo=timezone.utc)
            return value
        with mock.patch.object(edit_tests.edits.StaffOwnerFieldEdits, "detail", regressed):
            self.assertEqual(self.post(body)[0], 503)
            self.assertEqual(self.f.post("confirm", self.f.confirm_body(self.prepare))[0], 503)
        self.assertEqual(self.f.get(self.f.id)[1]["application"], self.claim)
        self.f.id = second["commandID"]
        prepare = self.f.prepare_body(reviewedConflict=True)
        with mock.patch.object(edit_tests.edits.StaffOwnerFieldEdits, "detail", regressed):
            self.assertEqual(self.f.post("prepare", prepare)[0], 503)
        self.assertIsNone(self.f.get(self.f.id)[1]["application"])
