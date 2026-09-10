from __future__ import annotations

import json
import unittest
import uuid
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import staff_workspace_commands as commands
from Backend import test_staff_workspace_cloud as cloud_http
from Backend import test_staff_workspace_delivery as content_http


class StaffWorkspaceCommandsHTTPTests(unittest.TestCase):
    Fixture = cloud_http.StaffWorkspaceCloudHTTPTests
    setUp, tearDown, request = Fixture.setUp, Fixture.tearDown, Fixture.request
    workspace, binding_payload, bind = Fixture.workspace, Fixture.binding_payload, Fixture.bind
    prepare, enroll, change = Fixture.prepare, Fixture.enroll, Fixture.change
    requested, advance, accepted = Fixture.requested, Fixture.advance, Fixture.accepted
    root, participant_name, participant_hash = Fixture.root, Fixture.participant_name, Fixture.participant_hash
    write_source, post = Fixture.write_source, Fixture.post
    deliver = Fixture.deliver
    seed = Fixture.seed

    def seed_content(self, role="Field Technician"):
        self.prepare()
        self.scope = dict(companyID=self.company, environment="development",
                          replicaID=self.workspace()["bindings"][0]["replicaID"])
        self.records = content_http.content_fixtures.rich_records(self.company, self.scope["replicaID"])
        self.write_source(self.records, 0)
        self.sequence = 1
        self.share = self.accepted(role)
        self.endpoint = self.root + "/" + self.share["id"] + "/full-selections"
        self.payload = dict(**self.scope, operationID=str(uuid.uuid4()), expectedSourceSequence=1,
                            expectedShareRevision=self.share["revision"],
                            sourceSchemaDigest=content_http.contract.SCHEMA_DIGEST)
        status, result = self.post()
        self.assertEqual(status, 200, result)
        self.content_path = self.endpoint + "/" + self.payload["operationID"] + "/content"
        status, receipt = self.deliver()
        self.assertEqual(status, 200, receipt)
        self.receipt = receipt
        job = content_http.fixtures.row(self.records, "job")
        self.job_id = job["id"]
        self.job_revision = job["revision"]
        return receipt

    def command_path(self):
        return self.content_path + "/commands"

    def command_body(self, **changes):
        body = dict(
            schema=commands.SCHEMA,
            **self.scope,
            commandID=str(uuid.uuid4()),
            selectionID=self.payload["operationID"],
            sourceSequence=self.receipt["sourceSequence"],
            contentSHA256=self.receipt["contentSHA256"],
            recordKind="job",
            recordID=self.job_id,
            expectedRevision=self.job_revision,
            fieldName="notes",
            value={"text": {"_0": "Field note from command path"}},
        )
        body.update(changes)
        return body

    def submit(self, role="Field Technician", body=None):
        return self.request(token=self.tokens[role], path=self.command_path(), method="POST",
                            payload=body if body is not None else self.command_body())

    def test_field_technician_operations_command_happy_path(self):
        self.seed_content()
        body = self.command_body()
        status, receipt = self.submit(body=body)
        self.assertEqual(status, 200, receipt)
        self.assertEqual(receipt["schema"], commands.SCHEMA)
        self.assertEqual(receipt["commandID"], body["commandID"])
        self.assertEqual(receipt["selectionID"], body["selectionID"])
        self.assertEqual(receipt["sourceSequence"], body["sourceSequence"])
        self.assertEqual(receipt["contentSHA256"], body["contentSHA256"])
        self.assertEqual(receipt["recordKind"], "job")
        self.assertEqual(receipt["recordID"], self.job_id)
        self.assertEqual(receipt["expectedRevision"], self.job_revision)
        self.assertEqual(receipt["fieldName"], "notes")
        self.assertEqual(receipt["value"], body["value"])
        self.assertEqual(receipt["state"], "recorded")
        self.assertFalse(receipt["operationalWorkspaceReady"])
        self.assertIn("createdAt", receipt)
        self.assertIn("actorEmail", receipt)

    def test_idempotent_replay_returns_same_receipt(self):
        self.seed_content()
        body = self.command_body()
        status, first = self.submit(body=body)
        self.assertEqual(status, 200, first)
        status, second = self.submit(body=body)
        self.assertEqual(status, 200, second)
        self.assertEqual(second, first)
        conflict = dict(body)
        conflict["value"] = {"text": {"_0": "different body for same commandID"}}
        status, result = self.submit(body=conflict)
        self.assertEqual(status, 409, result)
        self.assertEqual(result["code"], "command_conflict")

    def test_revision_conflict_is_rejected(self):
        self.seed_content()
        body = self.command_body(expectedRevision=self.job_revision + 1)
        status, result = self.submit(body=body)
        self.assertEqual(status, 409, result)
        self.assertEqual(result["code"], "revision_conflict")

    def test_command_values_are_encrypted_and_restart_recovers_exact_receipt(self):
        self.seed_content()
        body = self.command_body(value={"text": {"_0": "PRIVATE-FIELD-FINDING-417"}})
        status, original = self.submit(body=body)
        self.assertEqual(status, 200, original)
        with backend.db() as connection:
            saved = connection.execute("SELECT payload FROM staff_workspace_commands WHERE command_id=?", (body["commandID"],)).fetchone()[0]
        self.assertNotIn("PRIVATE-FIELD-FINDING-417", saved)
        decoded = json.loads(backend.decrypt_catalog_payload(saved))
        self.assertEqual(decoded["receipt"], original)
        backend.initialize_database()
        self.assertEqual(self.submit(body=body), (200, original))

    def test_another_actor_cannot_replay_a_staff_command_identity(self):
        self.seed_content()
        body = self.command_body()
        self.assertEqual(self.submit(body=body)[0], 200)
        self.assertEqual(self.submit(role="Admin", body=body)[0], 403)

    def test_encryption_failure_cannot_leave_a_partial_command(self):
        self.seed_content()
        body = self.command_body()
        with mock.patch.object(backend, "encrypt_catalog_payload", side_effect=RuntimeError("fixture unavailable")):
            self.assertEqual(self.submit(body=body)[0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM staff_workspace_commands").fetchone()[0], 0)
        self.assertEqual(self.submit(body=body)[0], 200)

    def test_corrupt_original_receipt_is_retained_and_never_reinterpreted(self):
        self.seed_content()
        body = self.command_body()
        self.assertEqual(self.submit(body=body)[0], 200)
        with backend.db() as connection:
            original = connection.execute("SELECT payload FROM staff_workspace_commands WHERE command_id=?", (body["commandID"],)).fetchone()[0]
        decoded = json.loads(original if original.startswith("{") else backend.decrypt_catalog_payload(original))
        for field, value in [("actorEmail", "foreign@example.invalid"), ("state", "applied"),
                             ("createdAt", "wrong"), ("value", {"text": {"_0": "different finding"}})]:
            saved = json.loads(json.dumps(decoded)); saved["receipt"][field] = value
            encrypted = backend.encrypt_catalog_payload(json.dumps(saved))
            with backend.db() as connection:
                connection.execute("UPDATE staff_workspace_commands SET payload=? WHERE command_id=?", (encrypted, body["commandID"]))
            status, result = self.submit(body=body)
            self.assertEqual(status, 503, (field, result))
            with backend.db() as connection:
                self.assertEqual(connection.execute("SELECT payload FROM staff_workspace_commands WHERE command_id=?", (body["commandID"],)).fetchone()[0], encrypted)

    def test_unavailable_and_financial_fields_are_rejected(self):
        self.seed_content()
        # findingsSummary is operations for Field Tech — use a shared/financial field instead.
        body = self.command_body(fieldName="status")  # shared, not operations
        status, result = self.submit(body=body)
        self.assertEqual(status, 403, result)
        self.assertEqual(result["code"], "command_field_unavailable")
        body = self.command_body(recordKind="payment", recordID=content_http.fixtures.row(self.records, "payment")["id"],
                                fieldName="amount", value={"number": {"_0": 1.0}})
        # payment is not an OPERATIONS kind
        status, result = self.submit(body=body)
        self.assertEqual(status, 403, result)
        self.assertEqual(result["code"], "command_field_unavailable")

    def test_accounting_role_cannot_command_operations_fields(self):
        self.seed_content(role="Accounting")
        # Accounting projection places notes in unavailableFields.
        body = self.command_body()
        status, result = self.submit(role="Accounting", body=body)
        self.assertIn(status, (403,), result)
        self.assertIn(result["code"], ("command_field_unavailable", "command_forbidden"))

    def test_missing_content_is_rejected(self):
        self.prepare()
        self.scope = dict(companyID=self.company, environment="development",
                          replicaID=self.workspace()["bindings"][0]["replicaID"])
        self.records = content_http.content_fixtures.rich_records(self.company, self.scope["replicaID"])
        self.write_source(self.records, 0)
        self.share = self.accepted()
        self.endpoint = self.root + "/" + self.share["id"] + "/full-selections"
        self.payload = dict(**self.scope, operationID=str(uuid.uuid4()), expectedSourceSequence=1,
                            expectedShareRevision=self.share["revision"],
                            sourceSchemaDigest=content_http.contract.SCHEMA_DIGEST)
        status, result = self.post()
        self.assertEqual(status, 200, result)
        self.content_path = self.endpoint + "/" + self.payload["operationID"] + "/content"
        # Selection exists but content was never prepared.
        job = content_http.fixtures.row(self.records, "job")
        self.job_id = job["id"]
        self.job_revision = job["revision"]
        self.receipt = dict(sourceSequence=1, contentSHA256="a" * 64)
        body = self.command_body()
        status, result = self.submit(body=body)
        self.assertEqual(status, 404, result)
        self.assertEqual(result["code"], "content_not_prepared")

    def test_wrong_content_digest_is_rejected(self):
        receipt = self.seed_content()
        body = self.command_body(contentSHA256="b" * 64)
        status, result = self.submit(body=body)
        self.assertEqual(status, 409, result)
        self.assertEqual(result["code"], "content_changed")
        self.assertFalse(receipt["operationalWorkspaceReady"])

    def test_query_and_oversized_body_are_rejected(self):
        self.seed_content()
        status, result = self.request(
            token=self.tokens["Field Technician"],
            path=self.command_path() + "?companyID=" + self.scope["companyID"],
            method="POST", payload=self.command_body())
        self.assertIn(status, (400, 404), result)


if __name__ == "__main__":
    unittest.main()
