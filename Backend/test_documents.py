from __future__ import annotations

import base64
import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from Backend import gunnaire_backend as backend


class AdminDocumentHandler(backend.GunnAireBackendHandler):
    def principal(self) -> dict[str, object]:
        return {
            "email": "admin@gunnaire.com",
            "role": "Admin",
            "isActive": True,
            "createdAt": None,
        }


class StandardDocumentHandler(backend.GunnAireBackendHandler):
    def principal(self) -> dict[str, object]:
        return {
            "email": "standard@gunnaire.com",
            "role": "Standard",
            "isActive": True,
            "createdAt": None,
        }


class DocumentTests(unittest.TestCase):
    def test_initialize_database_migrates_legacy_documents_table(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "gunnaire_backend.sqlite3"
            with sqlite3.connect(database) as connection:
                connection.execute(
                    """
                    CREATE TABLE documents (
                        id TEXT PRIMARY KEY,
                        filename TEXT NOT NULL,
                        content_type TEXT NOT NULL,
                        kind TEXT NOT NULL,
                        service_call_id TEXT,
                        stored_path TEXT NOT NULL,
                        created_at TEXT NOT NULL
                    )
                    """
                )

            with mock.patch.multiple(
                backend,
                DB_PATH=database,
                STORAGE_ROOT=root / "storage",
            ):
                backend.initialize_database()
                with backend.db() as migrated:
                    columns = {row["name"] for row in migrated.execute("PRAGMA table_info(documents)")}

            self.assertIn("maintenance_contract_id", columns)

    def test_agreement_document_upload_and_list_preserve_relationship(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contract_id = str(uuid.uuid4())
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), AdminDocumentHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                url = f"http://127.0.0.1:{server.server_port}/api/documents"
                payload = {
                    "filename": "agreement.pdf",
                    "contentType": "application/pdf",
                    "kind": "maintenance_agreement",
                    "maintenanceContractID": contract_id,
                    "customerName": "Agreement Customer",
                    "dataBase64": base64.b64encode(b"agreement-pdf").decode("ascii"),
                }
                request = urllib.request.Request(
                    url,
                    data=json.dumps(payload).encode("utf-8"),
                    method="POST",
                    headers={"Content-Type": "application/json"},
                )
                try:
                    with urllib.request.urlopen(request, timeout=5) as response:
                        created = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 201)

                    with urllib.request.urlopen(url, timeout=5) as response:
                        listed = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 200)
                    self.assertEqual(len(listed["documents"]), 1)
                    record = listed["documents"][0]
                    self.assertEqual(record["id"], created["id"])
                    self.assertEqual(record["maintenanceContractID"], contract_id)
                    self.assertEqual(record["kind"], "maintenance_agreement")
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_malformed_agreement_reference_is_rejected_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), AdminDocumentHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                request = urllib.request.Request(
                    f"http://127.0.0.1:{server.server_port}/api/documents",
                    data=json.dumps(
                        {
                            "filename": "agreement.pdf",
                            "contentType": "application/pdf",
                            "kind": "maintenance_agreement",
                            "maintenanceContractID": "not-a-uuid",
                            "dataBase64": base64.b64encode(b"agreement-pdf").decode("ascii"),
                        }
                    ).encode("utf-8"),
                    method="POST",
                    headers={"Content-Type": "application/json"},
                )
                try:
                    with self.assertRaises(urllib.error.HTTPError) as rejected:
                        urllib.request.urlopen(request, timeout=5)
                    self.assertEqual(rejected.exception.code, 400)
                    self.assertFalse(any((root / "storage").rglob("*")))
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_standard_user_cannot_upload_financial_agreement_document(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), StandardDocumentHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                request = urllib.request.Request(
                    f"http://127.0.0.1:{server.server_port}/api/documents",
                    data=json.dumps(
                        {
                            "filename": "agreement.pdf",
                            "contentType": "application/pdf",
                            "kind": "maintenance_agreement",
                            "maintenanceContractID": str(uuid.uuid4()),
                            "dataBase64": base64.b64encode(b"agreement-pdf").decode("ascii"),
                        }
                    ).encode("utf-8"),
                    method="POST",
                    headers={"Content-Type": "application/json"},
                )
                try:
                    with self.assertRaises(urllib.error.HTTPError) as rejected:
                        urllib.request.urlopen(request, timeout=5)
                    self.assertEqual(rejected.exception.code, 403)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
