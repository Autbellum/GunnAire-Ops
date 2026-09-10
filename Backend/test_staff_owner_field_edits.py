import json
import unittest
import urllib.parse
import uuid
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import staff_owner_field_edits as edits
from Backend import test_staff_workspace_commands as command_tests


class OwnerFieldEditHTTPTests(unittest.TestCase):
    def setUp(self):
        self.f = command_tests.StaffWorkspaceCommandsHTTPTests()
        self.f.setUp()
        self.addCleanup(self.f.tearDown)
        self.f.seed_content()
        self.command = self.f.command_body()
        status, self.receipt = self.f.submit(body=self.command)
        self.assertEqual(status, 200)
        self.id = self.command["commandID"]
        self.root = "/api/workspace/field-edits"
        self.query = "?" + urllib.parse.urlencode(self.f.scope)
        self.owner_store = str(uuid.uuid4())

    def get(self, command=None, role="Admin"):
        return self.f.request(token=self.f.tokens[role], path=self.root + ("/" + command if command else "") + self.query)

    def prepare_body(self, **changes):
        status, detail = self.get(self.id)
        self.assertEqual(status, 200, detail)
        body = dict(**self.f.scope, schema=edits.SCHEMA, commandID=self.id, operationID=str(uuid.uuid4()),
                    ownerStoreID=self.owner_store, expectedRevision=detail["current"]["revision"],
                    expectedValue=detail["current"]["value"], reviewedConflict=False)
        body.update(changes)
        return body

    def post(self, action, body, role="Admin"):
        return self.f.request(token=self.f.tokens[role], path=self.root + "/" + self.id + "/" + action, method="POST", payload=body)

    def confirm_body(self, body):
        return {key: body[key] for key in edits.CONFIRM.split()}

    def advance_job(self, note):
        fixture = command_tests.content_http.fixtures
        job = fixture.row(self.f.records, "job")
        fixture.set_value(job, "notes", note)
        self.f.write_source([job], 1, 1)

    def test_actual_source_confirmation_not_just_a_recorded_receipt(self):
        self.assertEqual(self.get()[1]["commandIDs"], [self.id])
        body = self.prepare_body()
        status, prepared = self.post("prepare", body)
        self.assertEqual(status, 200, prepared)
        self.assertEqual(prepared["state"], "prepared")
        backend.initialize_database()
        self.assertEqual(self.post("prepare", body), (200, prepared))
        self.assertEqual(self.post("confirm", self.confirm_body(body))[1]["code"], "edit_not_published")
        self.advance_job(self.command["value"]["text"]["_0"])
        status, published = self.post("confirm", self.confirm_body(body))
        self.assertEqual(status, 200, published)
        self.assertEqual(published["state"], "published")
        self.assertEqual(self.post("confirm", self.confirm_body(body)), (200, published))
        self.assertEqual(self.get()[1]["commandIDs"], [])
        detail = self.get(self.id)[1]
        self.assertEqual(detail["receipt"], self.receipt)
        self.assertNotEqual(detail["baseValue"], self.command["value"])

    def test_current_owner_company_and_staff_authority_are_required(self):
        for role in ("Field Technician", "Dispatcher", "Accounting", "Standard"):
            self.assertEqual(self.get(self.id, role=role)[0], 403)
        body = self.prepare_body()
        self.assertEqual(self.post("prepare", body, role="Field Technician")[0], 403)
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (self.receipt["actorEmail"],))
        self.assertFalse(self.get(self.id)[1]["eligible"])
        self.assertEqual(self.post("prepare", body)[0], 403)
        self.assertEqual(self.get(self.id)[1]["receipt"], self.receipt)

    def test_conflicting_office_value_requires_exact_review(self):
        original = self.prepare_body()
        self.advance_job("Office correction")
        self.assertEqual(self.post("prepare", original)[1]["code"], "field_changed")
        reviewed = self.prepare_body()
        self.assertEqual(self.post("prepare", reviewed)[1]["code"], "field_changed")
        reviewed["reviewedConflict"] = True
        self.assertEqual(self.post("prepare", reviewed)[0], 200)

    def test_second_office_device_cannot_take_over_original_claim(self):
        body = self.prepare_body()
        self.assertEqual(self.post("prepare", body)[0], 200)
        for changes in ({"ownerStoreID": str(uuid.uuid4())}, {"operationID": str(uuid.uuid4())}):
            self.assertEqual(self.post("prepare", dict(body, **changes))[1]["code"], "edit_claimed")
        self.assertEqual(self.post("prepare", dict(body, reviewedConflict=True))[1]["code"], "edit_changed")
        self.assertEqual(self.get(self.id)[1]["application"]["operationID"], body["operationID"])

    def test_corrupt_application_cannot_hide_as_a_completed_inbox_item(self):
        body = self.prepare_body()
        self.assertEqual(self.post("prepare", body)[0], 200)
        with backend.db() as connection:
            connection.execute("UPDATE staff_owner_field_edit_applications SET state='published' WHERE command_id=?", (self.id,))
        self.assertEqual(self.get()[0], 503)
        self.assertEqual(self.get(self.id)[0], 503)

    def test_failed_encryption_does_not_reserve_a_partial_claim(self):
        body = self.prepare_body()
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("fixture unavailable")):
            self.assertEqual(self.post("prepare", body)[0], 503)
        self.assertIsNone(self.get(self.id)[1]["application"])
        self.assertEqual(self.post("prepare", body)[0], 200)

    def test_legacy_original_base_is_recovered_without_using_newer_office_data(self):
        original_base = self.get(self.id)[1]["baseValue"]
        with backend.db() as connection:
            row = connection.execute("SELECT payload FROM staff_workspace_commands WHERE command_id=?", (self.id,)).fetchone()
            saved = json.loads(backend.decrypt_catalog_payload(row[0]))
            saved.pop("baseValue")
            connection.execute("UPDATE staff_workspace_commands SET payload=? WHERE command_id=?",
                               (backend.encrypt_catalog_payload(json.dumps(saved)), self.id))
        self.advance_job("Later office note")
        status, detail = self.get(self.id)
        self.assertEqual(status, 200, detail)
        self.assertEqual(detail["baseValue"], original_base)
        self.assertEqual(detail["current"]["value"], {"text": {"_0": "Later office note"}})

    def test_saved_publication_can_be_confirmed_after_staff_revocation(self):
        body = self.prepare_body()
        self.assertEqual(self.post("prepare", body)[0], 200)
        self.advance_job(self.command["value"]["text"]["_0"])
        with backend.db() as connection:
            connection.execute("UPDATE users SET is_active=0 WHERE email=?", (self.receipt["actorEmail"],))
        self.assertFalse(self.get(self.id)[1]["eligible"])
        self.assertEqual(self.post("confirm", self.confirm_body(body))[1]["state"], "published")

    def test_exact_endpoints_payloads_and_scope_fail_closed(self):
        for suffix in ("/", "/" + self.id + "/", "/" + self.id + "?after=" + self.id + "&"):
            path = self.root + suffix + (self.query[1:] if "?" in suffix else self.query)
            self.assertEqual(self.f.request(token=self.f.tokens["Admin"], path=path)[0], 400)
        body = self.prepare_body()
        for changes in ({"ownerStoreID": "bad"}, {"reviewedConflict": 1}, {"expectedRevision": True},
                        {"expectedValue": {"flag": {"_0": True}}}, {"unexpected": 1}):
            self.assertEqual(self.post("prepare", dict(body, **changes))[0], 400)
        self.assertIsNone(self.get(self.id)[1]["application"])

    def test_operation_identity_cannot_be_reused_for_a_different_command(self):
        body = self.prepare_body()
        self.assertEqual(self.post("prepare", body)[0], 200)
        second = self.f.command_body()
        self.assertEqual(self.f.submit(body=second)[0], 200)
        self.id = second["commandID"]
        request = self.prepare_body(operationID=body["operationID"])
        self.assertEqual(self.post("prepare", request)[1]["code"], "edit_claimed")
        self.assertIsNone(self.get(self.id)[1]["application"])

    def test_corrupt_encrypted_receipt_never_hides_a_published_item(self):
        body = self.prepare_body()
        self.assertEqual(self.post("prepare", body)[0], 200)
        with backend.db() as connection:
            original = json.loads(backend.decrypt_catalog_payload(connection.execute(
                "SELECT ciphertext FROM staff_owner_field_edit_applications WHERE command_id=?", (self.id,)).fetchone()[0]))
        for key, value in (("preparedAt", "bad"), ("publishedAt", "bad"), ("reviewedConflict", 1),
                           ("expectedRevision", True), ("expectedValue", {"flag": {"_0": True}})):
            changed = json.loads(json.dumps(original))
            changed["receipt"].update(state="published", publishedAt="2026-09-10T23:59:59Z")
            changed["receipt"][key] = value
            if key in changed["request"]:
                changed["request"][key] = value
            with backend.db() as connection:
                connection.execute("UPDATE staff_owner_field_edit_applications SET state='published',ciphertext=? WHERE command_id=?",
                    (backend.encrypt_catalog_payload(json.dumps(changed)), self.id))
            self.assertEqual(self.get()[0], 503, key)

    def test_pagination_preserves_original_ids_and_scan_cursor(self):
        ids = [self.id]
        for _ in range(50):
            command = self.f.command_body()
            self.assertEqual(self.f.submit(body=command)[0], 200)
            ids.append(command["commandID"])
        first = self.get()[1]
        self.assertEqual(first["commandIDs"], sorted(ids)[:50])
        self.assertEqual(first["nextCursor"], sorted(ids)[49])
        path = self.root + self.query + "&after=" + first["nextCursor"]
        status, second = self.f.request(token=self.f.tokens["Admin"], path=path)
        self.assertEqual(status, 200)
        self.assertEqual(second["commandIDs"], sorted(ids)[50:])
        self.assertIsNone(second["nextCursor"])

    def test_large_unicode_office_values_survive_prepare_and_review(self):
        text = "é" * 500_000
        self.advance_job(text)
        body = self.prepare_body(reviewedConflict=True)
        self.assertGreater(len(json.dumps(body).encode()), 2 * 1024 * 1024)
        self.assertEqual(self.post("prepare", body)[0], 200)
        status, detail = self.get(self.id)
        self.assertEqual(status, 200)
        self.assertEqual(detail["current"]["value"], {"text": {"_0": text}})
        self.assertEqual(detail["application"]["expectedValue"], detail["current"]["value"])
        self.assertGreater(len(json.dumps(detail).encode()), 4 * 1024 * 1024)
