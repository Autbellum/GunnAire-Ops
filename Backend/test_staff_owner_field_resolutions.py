import json
import unittest
import uuid
from unittest import mock

from Backend import gunnaire_backend as backend, staff_owner_field_resolutions as resolutions
from Backend import test_staff_owner_field_edits as edit_tests


class OwnerFieldResolutionHTTPTests(unittest.TestCase):
    def setUp(self):
        self.f = edit_tests.OwnerFieldEditHTTPTests()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)

    def body(self):
        status, entry = self.f.get(self.f.id)
        self.assertEqual(status, 200)
        claim = entry["application"]
        return dict(**self.f.f.scope, schema=resolutions.SCHEMA, commandID=self.f.id, operationID=str(uuid.uuid4()),
            ownerStoreID=self.f.owner_store, claimOperationID=claim["operationID"] if claim else "",
            expectedRevision=entry["current"]["revision"], expectedValue=entry["current"]["value"])

    def keep(self, body, role="Admin"):
        return self.f.post("keep-office", body, role=role)

    def test_unclaimed_decision_retains_original_without_mutating_office_source(self):
        original = self.f.get(self.f.id)[1]
        body = self.body()
        status, receipt = self.keep(body)
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["outcome"], "keptOffice")
        self.assertEqual(receipt["request"], body)
        entry = self.f.get(self.f.id)[1]
        self.assertEqual(entry["current"], original["current"])
        self.assertEqual(entry["sourceSequence"], original["sourceSequence"])
        self.assertEqual(entry["request"], original["request"])
        self.assertEqual(entry["receipt"], original["receipt"])
        self.assertFalse(entry["eligible"])
        self.assertEqual(self.f.get()[1]["commandIDs"], [])
        backend.initialize_database()
        self.f.advance_job("Newer office correction after the decision")
        self.assertEqual(self.keep(body), (200, receipt), "Lost reply recovers the historical decision, not a newer value")
        self.assertEqual(self.f.post("prepare", self.f.prepare_body())[1]["code"], "edit_resolved")

    def test_prepared_third_value_conflict_is_resolved_only_on_original_device(self):
        original_claim = self.f.prepare_body()
        status, prepared = self.f.post("prepare", original_claim)
        self.assertEqual(status, 200)
        self.f.advance_job("Office kept a more recent equipment finding")
        body = self.body()
        self.assertEqual(self.keep(dict(body, ownerStoreID=str(uuid.uuid4())))[1]["code"], "edit_claimed")
        self.assertEqual(self.keep(dict(body, claimOperationID=""))[1]["code"], "edit_claimed")
        self.assertEqual(self.keep(body)[0], 200)
        entry = self.f.get(self.f.id)[1]
        self.assertEqual(entry["application"], prepared, "Do not rewrite the immutable original claim")
        self.assertEqual(entry["current"]["value"]["text"]["_0"], "Office kept a more recent equipment finding")
        self.assertEqual(self.f.post("prepare", original_claim)[1]["code"], "edit_resolved")
        self.assertEqual(self.f.post("confirm", self.f.confirm_body(original_claim))[1]["code"], "edit_resolved")

    def test_stale_review_and_concurrent_claim_cannot_be_silently_adopted(self):
        body = self.body()
        claim = self.f.prepare_body()
        self.assertEqual(self.f.post("prepare", claim)[0], 200)
        self.assertEqual(self.keep(body)[1]["code"], "edit_claimed")
        current = self.body()
        self.f.advance_job("A change after the owner opened review")
        self.assertEqual(self.keep(current)[1]["code"], "field_changed")
        self.assertNotIn("resolution", self.f.get(self.f.id)[1])

    def test_revocation_does_not_prevent_original_owner_retaining_without_applying(self):
        body = self.body()
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (self.f.receipt["actorEmail"],))
        self.assertEqual(self.keep(body)[0], 200)
        self.assertEqual(self.f.get(self.f.id)[1]["receipt"], self.f.receipt)

    def test_published_command_cannot_be_reclassified_as_kept_office(self):
        claim = self.f.prepare_body()
        self.assertEqual(self.f.post("prepare", claim)[0], 200)
        self.f.advance_job(self.f.command["value"]["text"]["_0"])
        self.assertEqual(self.f.post("confirm", self.f.confirm_body(claim))[0], 200)
        self.assertEqual(self.keep(self.body())[1]["code"], "edit_published")

    def test_authority_exact_identity_and_encryption_fail_closed(self):
        body = self.body()
        for role in ("Field Technician", "Dispatcher", "Accounting", "Standard"):
            self.assertEqual(self.keep(body, role=role)[0], 403)
        for changed in ({"ownerStoreID": "bad"}, {"claimOperationID": None}, {"expectedRevision": True},
                        {"expectedValue": {"flag": {"_0": True}}}, {"unknown": None}):
            self.assertEqual(self.keep(dict(body, **changed))[0], 400)
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("fixture encryption failure")):
            self.assertEqual(self.keep(body)[0], 503)
        self.assertNotIn("resolution", self.f.get(self.f.id)[1])
        status, receipt = self.keep(body)
        self.assertEqual(status, 200)
        self.assertEqual(self.keep(dict(body, operationID=str(uuid.uuid4())))[1]["code"], "edit_resolved")
        self.assertEqual(self.keep(body), (200, receipt))

    def test_corrupt_resolution_cannot_hide_an_original_in_the_inbox(self):
        body = self.body(); self.assertEqual(self.keep(body)[0], 200)
        with backend.db() as connection:
            row = connection.execute("SELECT ciphertext FROM staff_owner_field_resolutions WHERE command_id=?", (self.f.id,)).fetchone()
            original = json.loads(backend.decrypt_catalog_payload(row[0]))
        for key, value in (("resolvedAt", "bad"), ("resolvedAt", "1970-01-01T00:00:00Z"),
                           ("outcome", "published"), ("ownerEmail", "different@example.invalid")):
            changed = json.loads(json.dumps(original)); changed["receipt"][key] = value
            with backend.db() as connection:
                connection.execute("UPDATE staff_owner_field_resolutions SET ciphertext=? WHERE command_id=?",
                    (backend.encrypt_catalog_payload(json.dumps(changed)), self.f.id))
            self.assertEqual(self.f.get()[0], 503, key)
            self.assertEqual(self.f.get(self.f.id)[0], 503, key)

    def test_fully_resolved_first_page_still_exposes_the_next_scan_cursor(self):
        ids = [self.f.id]
        for _ in range(50):
            command = self.f.f.command_body()
            self.assertEqual(self.f.f.submit(body=command)[0], 200)
            ids.append(command["commandID"])
        ids.sort()
        for command_id in ids[:50]:
            self.f.id = command_id
            self.assertEqual(self.keep(self.body())[0], 200)
        first = self.f.get()[1]
        self.assertEqual(first["commandIDs"], [])
        self.assertEqual(first["nextCursor"], ids[49])
        path = self.f.root + self.f.query + "&after=" + first["nextCursor"]
        status, second = self.f.f.request(token=self.f.f.tokens["Admin"], path=path)
        self.assertEqual(status, 200)
        self.assertEqual(second["commandIDs"], ids[50:])
        self.assertIsNone(second["nextCursor"])

    def test_duplicate_decision_id_and_changed_retry_cannot_replace_a_decision(self):
        body = self.body(); status, receipt = self.keep(body)
        self.assertEqual(status, 200)
        for changed in ({"expectedRevision": body["expectedRevision"] + 1},
                        {"expectedValue": {"text": {"_0": "A changed retry"}}}):
            self.assertEqual(self.keep(dict(body, **changed))[1]["code"], "edit_resolved")
        self.assertEqual(self.keep(body), (200, receipt))
        command = self.f.f.command_body(); self.assertEqual(self.f.f.submit(body=command)[0], 200)
        self.f.id = command["commandID"]
        second = self.body(); second["operationID"] = body["operationID"]
        self.assertEqual(self.keep(second)[1]["code"], "edit_resolved")
        self.assertNotIn("resolution", self.f.get(self.f.id)[1])

    def test_large_unicode_keep_decision_uses_exact_original_value(self):
        note = "é" * 500_000
        self.f.advance_job(note)
        body = self.body(); status, receipt = self.keep(body)
        self.assertEqual(status, 200)
        self.assertEqual(receipt["request"]["expectedValue"]["text"]["_0"], note)
        entry = self.f.get(self.f.id)[1]
        self.assertEqual(entry["current"]["value"], receipt["request"]["expectedValue"])
        self.assertEqual(entry["receipt"], self.f.receipt)
