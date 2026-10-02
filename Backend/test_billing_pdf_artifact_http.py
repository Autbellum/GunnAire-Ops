"""Loopback-only HTTP fixture for authenticated billing artifact upload/read."""

import base64
import hashlib
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from unittest import mock
import urllib.parse
import urllib.request
import uuid

from Backend import gunnaire_backend as backend
from Backend.test_billing_pdf_archive_routes import FakeApprovedGoogleConnection


class ArtifactFixtureHandler(backend.GunnAireBackendHandler):
    def principal(self):
        return {"email": "owner@gunnaire.com", "role": "Admin", "isActive": True}

    def require_application_session(self):
        self._application_session_id = "approved-session"
        return True

    def google_connection_service(self):
        return FakeApprovedGoogleConnection()


class BillingPDFArtifactHTTPTests(unittest.TestCase):
    def test_http_upload_read_and_exact_backup_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            company, replica, grant, document = [str(uuid.uuid4()) for _ in range(4)]
            subject = "approved-google-subject"
            database = root / "backend.sqlite"
            storage = root / "storage"
            with mock.patch.multiple(backend, DB_PATH=database, STORAGE_ROOT=storage,
                                     PRIMARY_ADMIN_EMAIL="owner@gunnaire.com",
                                     CLOUDKIT_CONTAINER_ID="iCloud.com.gunnaire.businesssuite"):
                with sqlite3.connect(database) as connection:
                    connection.executescript("""
                        CREATE TABLE company_identity(singleton INTEGER PRIMARY KEY, company_id TEXT NOT NULL);
                        CREATE TABLE cloudkit_workspace_bindings(container_id TEXT, environment TEXT,
                            replica_id TEXT, cloud_account_hash TEXT);
                        CREATE TABLE google_connections(company_id TEXT, actor_email TEXT, id TEXT,
                            subject TEXT, state TEXT);
                        CREATE TABLE google_account_bindings(company_id TEXT, actor_email TEXT, subject TEXT);
                    """)
                    connection.execute("INSERT INTO company_identity VALUES (1, ?)", (company,))
                    connection.execute("INSERT INTO cloudkit_workspace_bindings VALUES (?,?,?,?)",
                        (backend.CLOUDKIT_CONTAINER_ID, "production", replica, "account-hash"))
                    connection.execute("INSERT INTO google_connections VALUES (?,?,?,?,?)",
                        (company, "owner@gunnaire.com", grant, subject, "active"))
                    connection.execute("INSERT INTO google_account_bindings VALUES (?,?,?)",
                        (company, "owner@gunnaire.com", subject))
                backend.billing_pdf_archive_ledger.BillingPDFArchiveLedger(database).install()
                server = ThreadingHTTPServer(("127.0.0.1", 0), ArtifactFixtureHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                endpoint = f"http://127.0.0.1:{server.server_port}/api/google/drive/billing-pdf-intents"
                identity = {"companyID": company, "grantID": grant,
                    "containerID": backend.CLOUDKIT_CONTAINER_ID, "environment": "production",
                    "replicaID": replica, "cloudAccountHash": "account-hash",
                    "expectedDriveAccount": "google-subject:" + hashlib.sha256(subject.encode()).hexdigest(),
                    "documentKind": "invoice", "documentID": document,
                    "sourceDigest": "a" * 64, "rendererVersion": "customer-pdf-v1"}
                pdf = b"%PDF-1.7\nserver-owned revision\n%%EOF\n"
                try:
                    reserve = urllib.request.Request(endpoint + "/reserve",
                        data=json.dumps(identity).encode(), method="POST")
                    with urllib.request.urlopen(reserve, timeout=5) as response:
                        reserved = json.load(response)["reservation"]
                    upload = urllib.request.Request(endpoint + "/artifact",
                        data=json.dumps({**identity, "leaseToken": reserved["lease_token"],
                            "contentDigest": hashlib.sha256(pdf).hexdigest(),
                            "dataBase64": base64.b64encode(pdf).decode()}).encode(), method="POST")
                    with urllib.request.urlopen(upload, timeout=5) as response:
                        receipt = json.load(response)
                    self.assertEqual(receipt["artifact"]["fileSHA256"], hashlib.sha256(pdf).hexdigest())
                    with urllib.request.urlopen(endpoint + "/artifact?" + urllib.parse.urlencode(identity),
                                                timeout=5) as response:
                        self.assertEqual(response.headers["Content-Type"], "application/pdf")
                        self.assertEqual(response.read(), pdf)
                    files = list(storage.rglob("*.pdf"))
                    self.assertEqual([file.name for file in files], [reserved["attachment_id"] + ".pdf"])
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
