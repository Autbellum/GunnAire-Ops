import base64
import hashlib
from pathlib import Path
import sqlite3
import unittest
import urllib.error
import urllib.request
import uuid
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import test_staff_workspace_media as media_tests


class DocumentContentProofHTTPTests(unittest.TestCase):
    def setUp(self):
        self.f = media_tests.StaffWorkspaceMediaHTTPTests()
        self.f.setUp()
        self.addCleanup(self.f.tearDown)

    def upload(self, payload=b"original-file", **changes):
        body = dict(filename="Report.pdf", contentType="application/pdf", kind="service_report",
                    dataBase64=base64.b64encode(payload).decode("ascii"))
        body.update(changes)
        return self.f.request(token=self.f.tokens["Admin"], path="/api/documents", method="POST", payload=body)

    def manifest(self, identifier, role="Admin"):
        return self.f.request(token=self.f.tokens[role], path=f"/api/documents/{identifier}/manifest")

    def row(self, identifier):
        with backend.db() as connection:
            return dict(connection.execute("SELECT * FROM documents WHERE id=?", (identifier,)).fetchone())

    def download(self, identifier, role="Admin"):
        request = urllib.request.Request(self.f.base_url + f"/api/documents/{identifier}/download",
            headers={"Authorization": "Bearer " + self.f.tokens[role]})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, response.read(), dict(response.headers)
        except urllib.error.HTTPError as error:
            return error.code, error.read(), dict(error.headers)

    def test_real_upload_persists_immutable_proof_and_native_manifest(self):
        status, uploaded = self.upload()
        self.assertEqual(status, 201, uploaded)
        row = self.row(uploaded["id"])
        self.assertEqual(row["file_sha256"], hashlib.sha256(b"original-file").hexdigest())
        self.assertEqual(row["file_size_bytes"], 13)
        status, proof = self.manifest(uploaded["id"])
        self.assertEqual(status, 200, proof)
        self.assertEqual(proof["fileSHA256"], uploaded["fileSHA256"])
        self.assertEqual(proof["schema"], backend.document_storage.PROOF_SCHEMA)
        status, data, headers = self.download(uploaded["id"])
        self.assertEqual((status, data), (200, b"original-file"))
        self.assertEqual(headers["Cache-Control"], "no-store")
        backend.initialize_database()
        self.assertEqual(self.row(uploaded["id"]), row)
        for column, value in (("file_sha256", "0" * 64), ("file_size_bytes", 14)):
            with self.assertRaises(sqlite3.IntegrityError), backend.db() as connection:
                connection.execute("UPDATE documents SET " + column + "=? WHERE id=?", (value, uploaded["id"]))

    def test_same_length_pre_read_swap_cannot_escape_either_download_route(self):
        self.f.seed_with_media()
        original = self.row(self.f.document_id)
        path = Path(original["stored_path"])
        changed = b"X" * len(self.f.payload_bytes)
        path.write_bytes(changed)
        self.assertEqual(self.f.media(bytes_path=True)[0], 409)
        self.assertEqual(self.download(self.f.document_id)[0], 409)
        self.assertEqual(path.read_bytes(), changed)
        self.assertEqual(self.row(self.f.document_id), original)

    def test_legacy_migration_keeps_original_row_and_file_without_inventing_proof(self):
        identifier = str(uuid.uuid4())
        self.f.install_document(identifier, verified=False)
        before = self.row(identifier)
        backend.initialize_database()
        self.assertEqual(self.row(identifier), before)
        self.assertEqual(self.manifest(identifier)[0], 409)
        with mock.patch.object(backend.document_storage.os, "read") as reader:
            self.assertEqual(self.download(identifier)[0], 409)
            reader.assert_not_called()
        self.assertIsNone(self.row(identifier)["file_sha256"])
        self.assertTrue(Path(before["stored_path"]).is_file())

    def test_missing_or_partial_proof_is_not_backfilled_during_staff_authorization(self):
        self.f.seed_with_media()
        with backend.db() as connection:
            # Simulate a legacy/corrupt restored database, not an application update.
            connection.execute("DROP TRIGGER documents_upload_proof_immutable_v1")
            connection.execute("UPDATE documents SET file_sha256=NULL,file_size_bytes=NULL")
        self.assertEqual(self.f.media()[0], 409)
        with backend.db() as connection:
            connection.execute("UPDATE documents SET file_size_bytes=27")
        self.assertEqual(self.f.media()[0], 503)
        self.assertIsNone(self.row(self.f.document_id)["file_sha256"])

    def test_general_download_rechecks_revocation_and_role_after_read(self):
        self.f.seed_with_media()
        for column, value in (("is_active", 0), ("role", "Standard")):
            original = backend.document_storage.read_document
            def read(*args, **kwargs):
                data = original(*args, **kwargs)
                with backend.db() as connection:
                    connection.execute("UPDATE users SET " + column + "=? WHERE role='Admin'", (value,))
                return data
            with mock.patch.object(backend.document_storage, "read_document", side_effect=read):
                self.assertEqual(self.download(self.f.document_id)[0], 403)
            # Restore only the isolated user's activity before testing role revocation.
            if column == "is_active":
                with backend.db() as connection:
                    connection.execute("UPDATE users SET is_active=1 WHERE role='Admin'")

    def test_general_download_rechecks_exact_record_binding_after_read(self):
        status, uploaded = self.upload()
        self.assertEqual(status, 201)
        original = backend.document_storage.read_document
        def read(*args, **kwargs):
            data = original(*args, **kwargs)
            with backend.db() as connection:
                connection.execute("UPDATE documents SET invoice_id='later-invoice' WHERE id=?", (uploaded["id"],))
            return data
        with mock.patch.object(backend.document_storage, "read_document", side_effect=read):
            self.assertEqual(self.download(uploaded["id"])[0], 409)

    def test_financial_manifest_has_the_same_role_gate_as_download(self):
        status, uploaded = self.upload(kind="invoice")
        self.assertEqual(status, 201)
        for role in ("Dispatcher", "Standard"):
            self.assertEqual(self.manifest(uploaded["id"], role)[0], 403)
            self.assertEqual(self.download(uploaded["id"], role)[0], 403)

    def test_exact_paths_and_metadata_are_required(self):
        identifier = self.upload()[1]["id"]
        for suffix in ("/manifest?extra=1", "/manifest/", "/other", "/download?extra=1"):
            self.assertEqual(self.f.request(token=self.f.tokens["Admin"], path="/api/documents/" + identifier + suffix)[0], 400)
        for content_type in ("text/plain\r\nX: leak", "text", "a/" + "b" * 128):
            self.assertEqual(self.upload(contentType=content_type)[0], 400)

    def test_failed_upload_readback_never_commits_a_false_proof(self):
        original = Path.write_bytes
        def replaced(path, value):
            return original(path, b"X" * len(value))
        with mock.patch.object(Path, "write_bytes", replaced):
            self.assertEqual(self.upload()[0], 503)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM documents").fetchone()[0], 0)

    def test_revocation_during_upload_readback_cannot_commit_document_metadata(self):
        original = backend.document_storage.read_document
        def read(*args, **kwargs):
            data = original(*args, **kwargs)
            with backend.db() as connection:
                connection.execute("UPDATE users SET is_active=0 WHERE role='Admin'")
            return data
        with mock.patch.object(backend.document_storage, "read_document", side_effect=read):
            self.assertEqual(self.upload()[0], 403)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM documents").fetchone()[0], 0)
