from __future__ import annotations

import json
import unittest
import urllib.parse
import uuid
from unittest import mock
from pathlib import Path

from Backend import gunnaire_backend as backend
from Backend import staff_workspace_media as media
from Backend import staff_workspace_projection as projection
from Backend import test_staff_workspace_cloud as cloud_http
from Backend import test_staff_workspace_delivery as content_http


class StaffWorkspaceMediaHTTPTests(unittest.TestCase):
    Fixture = cloud_http.StaffWorkspaceCloudHTTPTests
    setUp, tearDown, request = Fixture.setUp, Fixture.tearDown, Fixture.request
    workspace, binding_payload, bind = Fixture.workspace, Fixture.binding_payload, Fixture.bind
    prepare, enroll, change = Fixture.prepare, Fixture.enroll, Fixture.change
    requested, advance, accepted = Fixture.requested, Fixture.advance, Fixture.accepted
    root, participant_name, participant_hash = Fixture.root, Fixture.participant_name, Fixture.participant_hash
    write_source, post = Fixture.write_source, Fixture.post
    deliver = Fixture.deliver
    seed = Fixture.seed

    def media_path(self, bytes_path=False):
        suffix = "/media/bytes" if bytes_path else "/media"
        return self.content_path + suffix

    def media(self, role="Field Technician", attachment_id=None, bytes_path=False, query=None):
        values = dict(self.scope, attachmentID=attachment_id or self.attachment_id)
        if query is not None:
            values = query
        path = self.media_path(bytes_path=bytes_path) + "?" + urllib.parse.urlencode(values)
        return self.request(token=self.tokens[role], path=path)

    def install_document(self, document_id, payload=b"%PDF-fixture-media-1234567890"):
        storage = Path(backend.STORAGE_ROOT)
        storage.mkdir(parents=True, exist_ok=True)
        path = storage / f"{document_id}.pdf"
        path.write_bytes(payload)
        with backend.db() as connection:
            connection.execute(
                """INSERT INTO documents
                   (id, filename, content_type, kind, service_call_id, invoice_id, estimate_id,
                    maintenance_contract_id, customer_equipment_id, equipment_name, customer_name,
                    stored_path, created_at)
                   VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?)""",
                (document_id, "Original.pdf", "application/pdf", "service_report",
                 str(path), backend.utc_now()),
            )
        return payload

    def seed_with_media(self, role="Field Technician"):
        self.prepare()
        self.scope = dict(companyID=self.company, environment="development",
                          replicaID=self.workspace()["bindings"][0]["replicaID"])
        self.records = content_http.content_fixtures.rich_records(self.company, self.scope["replicaID"])
        attachment = content_http.fixtures.row(self.records, "attachment")
        self.attachment_id = attachment["id"]
        self.document_id = str(uuid.uuid4())
        self.payload_bytes = b"%PDF-fixture-media-1234567890"
        content_http.fixtures.set_value(attachment, "backendDocumentID", self.document_id)
        content_http.fixtures.set_value(attachment, "fileSizeBytes", len(self.payload_bytes))
        content_http.fixtures.set_value(attachment, "displayName", "Original.pdf")
        content_http.fixtures.set_value(attachment, "contentType", "application/pdf")
        self.install_document(self.document_id, self.payload_bytes)
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
        return receipt

    def test_staff_media_grant_requires_backend_document_and_selection(self):
        receipt = self.seed_with_media()
        status, grant = self.media()
        self.assertEqual(status, 200, grant)
        self.assertEqual(grant["schema"], media.SCHEMA)
        self.assertEqual(grant["attachmentID"], self.attachment_id)
        self.assertEqual(grant["backendDocumentID"], self.document_id)
        self.assertEqual(grant["fileSizeBytes"], len(self.payload_bytes))
        self.assertEqual(grant["contentType"], "application/pdf")
        self.assertEqual(grant["displayName"], "Original.pdf")
        self.assertFalse(grant["operationalWorkspaceReady"])
        self.assertEqual(grant["selectionID"], self.payload["operationID"])
        self.assertEqual(grant["sourceSequence"], receipt["sourceSequence"])
        self.assertEqual(grant["contentSHA256"], receipt["contentSHA256"])

        import urllib.request
        path = self.media_path(bytes_path=True) + "?" + urllib.parse.urlencode(
            dict(self.scope, attachmentID=self.attachment_id))
        request = urllib.request.Request(
            self.base_url + path, method="GET",
            headers={"Authorization": "Bearer " + self.tokens["Field Technician"]})
        with urllib.request.urlopen(request, timeout=10) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers.get("Content-Type"), "application/pdf")
            self.assertEqual(response.read(), self.payload_bytes)

    def test_null_backend_document_id_is_not_capability(self):
        self.assertEqual(self.seed()[0], 200)
        attachment = content_http.fixtures.row(self.records, "attachment")
        self.attachment_id = attachment["id"]
        status, result = self.media()
        self.assertEqual(status, 404, result)
        self.assertEqual(result["code"], "media_unavailable")

    def test_unknown_attachment_and_foreign_id_are_rejected(self):
        self.seed_with_media()
        status, result = self.media(attachment_id=str(uuid.uuid4()))
        self.assertEqual(status, 404, result)
        self.assertEqual(result["code"], "media_not_selected")
        status, result = self.media(query=dict(self.scope, attachmentID=self.attachment_id, extra="1"))
        self.assertEqual(status, 400, result)

    def test_source_advance_blocks_media_without_replacing_content(self):
        receipt = self.seed_with_media()
        self.assertEqual(self.media()[0], 200)
        equipment = content_http.fixtures.row(self.records, "equipment")
        content_http.fixtures.set_value(equipment, "notes", "advanced after media")
        self.write_source([equipment], 1, 1)
        status, result = self.media()
        self.assertEqual(status, 409, result)
        self.assertEqual(result["code"], "source_changed")
        with backend.db() as connection:
            marker = connection.execute(
                "SELECT content_sha256 FROM staff_workspace_projections WHERE selection_id=?",
                (self.payload["operationID"],)).fetchone()[0]
        self.assertEqual(marker, receipt["contentSHA256"])

    def test_missing_document_row_is_unavailable(self):
        self.seed_with_media()
        with backend.db() as connection:
            connection.execute("DELETE FROM documents WHERE id=?", (self.document_id,))
        status, result = self.media()
        self.assertEqual(status, 404, result)
        self.assertEqual(result["code"], "media_unavailable")

    def test_symlink_in_storage_is_not_media_authority(self):
        self.seed_with_media()
        target = Path(backend.STORAGE_ROOT) / f"{self.document_id}.pdf"
        link = target.with_suffix(".link")
        link.symlink_to(target)
        with backend.db() as connection:
            connection.execute("UPDATE documents SET stored_path=? WHERE id=?", (str(link), self.document_id))
        self.assertEqual(self.media(bytes_path=True)[0], 403)

    def test_mismatched_size_is_rejected_without_unbounded_read(self):
        self.seed_with_media()
        target = Path(backend.STORAGE_ROOT) / f"{self.document_id}.pdf"
        target.write_bytes(self.payload_bytes + b"unexpected newer bytes")
        with mock.patch.object(Path, "read_bytes", wraps=Path.read_bytes) as unbounded:
            self.assertEqual(self.media(bytes_path=True)[0], 409)
            unbounded.assert_not_called()

    def test_dispatcher_cannot_use_shared_attachment_to_read_financial_document(self):
        self.seed_with_media(role="Dispatcher")
        with backend.db() as connection:
            connection.execute("UPDATE documents SET invoice_id=? WHERE id=?", (str(uuid.uuid4()), self.document_id))
        self.assertEqual(self.media(role="Dispatcher")[0], 403)
        self.assertEqual(self.media(role="Dispatcher", bytes_path=True)[0], 403)

    def test_header_metadata_rejects_embedded_controls(self):
        for value in ("application/pdf\r\nX-Injected: yes", "Original\x00.pdf", "Original\n.pdf"):
            with self.subTest(value=repr(value)):
                with self.assertRaises(ValueError):
                    media.field_text({"field": {"text": {"_0": value}}}, "field")

    def test_deactivation_during_read_cannot_release_authorized_bytes(self):
        self.seed_with_media()
        original_read = media.document_storage.read_document
        def read(*args, **kwargs):
            data = original_read(*args, **kwargs)
            with backend.db() as connection:
                connection.execute("UPDATE users SET is_active=0 WHERE role='Field Technician'")
            return data
        with mock.patch.object(media.document_storage, "read_document", side_effect=read):
            self.assertIn(self.media(bytes_path=True)[0], (401, 403))

    def test_document_binding_change_during_read_cannot_release_old_bytes(self):
        self.seed_with_media()
        original_read = media.document_storage.read_document
        def read(*args, **kwargs):
            data = original_read(*args, **kwargs)
            with backend.db() as connection:
                connection.execute("UPDATE documents SET filename='Changed.pdf' WHERE id=?", (self.document_id,))
            return data
        with mock.patch.object(media.document_storage, "read_document", side_effect=read):
            self.assertEqual(self.media(bytes_path=True)[0], 409)

    def test_general_document_download_uses_the_same_bounded_reader(self):
        self.seed_with_media()
        target = Path(backend.STORAGE_ROOT) / f"{self.document_id}.pdf"
        with target.open("r+b") as file:
            file.truncate(media.document_storage.MAX_BYTES + 1)
        with mock.patch.object(media.document_storage.os, "read") as read:
            status, _ = self.request(token=self.tokens["Field Technician"],
                                     path=f"/api/documents/{self.document_id}/download")
            self.assertEqual(status, 409)
            read.assert_not_called()

    def test_general_document_download_keeps_exact_bytes_and_private_headers(self):
        self.seed_with_media()
        import urllib.request
        request = urllib.request.Request(self.base_url + f"/api/documents/{self.document_id}/download",
            headers={"Authorization": "Bearer " + self.tokens["Field Technician"]})
        with urllib.request.urlopen(request, timeout=10) as response:
            self.assertEqual(response.read(), self.payload_bytes)
            self.assertEqual(response.headers.get("Content-Type"), "application/pdf")
            self.assertEqual(response.headers.get("Cache-Control"), "no-store")
            self.assertEqual(response.headers.get("X-Content-Type-Options"), "nosniff")


if __name__ == "__main__":
    unittest.main()
