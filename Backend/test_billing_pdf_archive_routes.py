from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid

from Backend import google_connections
from Backend.billing_pdf_archive_ledger import BillingPDFArchiveLedger
from Backend.billing_pdf_archive_routes import BillingPDFArchiveRoutes, RouteFailure


class FakeApprovedGoogleConnection:
    def __init__(self, *, email="owner@gunnaire.com", role="Admin"):
        self.email, self.role = email, role

    def configured(self):
        pass

    def authorize(self, connection, session_id, company):
        if session_id != "approved-session":
            raise google_connections.ConnectionError("access_required", "Sign in again.", 403)
        expected = connection.execute("SELECT company_id FROM company_identity WHERE singleton=1").fetchone()
        if expected is None or expected[0] != company:
            raise google_connections.ConnectionError("company_changed", "Reopen the original company.", 403)
        return {"email": self.email, "role": self.role}

    def grant(self, connection, company, owner):
        return connection.execute("SELECT * FROM google_connections WHERE company_id=? AND actor_email=?",
                                  (company, owner)).fetchone()

    def check_grant(self, row, grant_id, scopes):
        if row is None or row["id"] != grant_id or row["state"] != "active" or scopes != google_connections.FEATURE_SCOPES["drive"]:
            raise google_connections.ConnectionError("connection_changed", "Reconnect Google.", 403)


class BillingPDFArchiveRoutesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "backend.sqlite"
        self.company = str(uuid.uuid4())
        self.grant = str(uuid.uuid4())
        self.replica = str(uuid.uuid4())
        self.document = str(uuid.uuid4())
        self.subject = "google-subject-1"
        self.google = FakeApprovedGoogleConnection()
        self.ledger = BillingPDFArchiveLedger(self.path)
        self.ledger.install()
        with self.database() as connection:
            connection.executescript("""
                CREATE TABLE company_identity(singleton INTEGER PRIMARY KEY, company_id TEXT NOT NULL);
                CREATE TABLE cloudkit_workspace_bindings(container_id TEXT, environment TEXT,
                    replica_id TEXT, cloud_account_hash TEXT);
                CREATE TABLE google_connections(company_id TEXT, actor_email TEXT, id TEXT,
                    subject TEXT, state TEXT);
                CREATE TABLE google_account_bindings(company_id TEXT, actor_email TEXT, subject TEXT);
            """)
            connection.execute("INSERT INTO company_identity VALUES (1, ?)", (self.company,))
            connection.execute("INSERT INTO cloudkit_workspace_bindings VALUES (?,?,?,?)",
                               ("iCloud.com.gunnaire.businesssuite", "production", self.replica, "account-hash"))
            connection.execute("INSERT INTO google_connections VALUES (?,?,?,?,?)",
                               (self.company, "owner@gunnaire.com", self.grant, self.subject, "active"))
            connection.execute("INSERT INTO google_account_bindings VALUES (?,?,?)",
                               (self.company, "owner@gunnaire.com", self.subject))
        self.routes = BillingPDFArchiveRoutes(self.database, self.google,
            primary_admin_email="owner@gunnaire.com", container_id="iCloud.com.gunnaire.businesssuite",
            ledger=self.ledger)
        self.payload = {
            "companyID": self.company, "grantID": self.grant,
            "containerID": "iCloud.com.gunnaire.businesssuite", "environment": "production",
            "replicaID": self.replica, "cloudAccountHash": "account-hash",
            "documentKind": "invoice", "documentID": self.document,
            "sourceDigest": "a" * 64, "rendererVersion": "customer-pdf-v1",
        }

    def database(self):
        connection = sqlite3.connect(self.path)
        connection.row_factory = sqlite3.Row
        return connection

    def test_reserve_and_read_do_not_leak_live_lease(self):
        original = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                        self.payload, "approved-session")["reservation"]
        self.assertIsNotNone(original["lease_token"])
        readback = self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
                                        self.payload, "approved-session")["reservation"]
        self.assertNotIn("lease_token", readback)
        self.assertEqual(readback["attachment_id"], original["attachment_id"])
        with self.assertRaisesRegex(RouteFailure, "Another device"):
            self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                 self.payload, "approved-session")
        content = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/content",
            {**self.payload, "leaseToken": original["lease_token"], "contentDigest": "b" * 64},
            "approved-session")["reservation"]
        self.assertEqual(content["content_digest"], "b" * 64)
        file = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/file",
            {**self.payload, "leaseToken": original["lease_token"], "fileID": "reserved-id"},
            "approved-session")["reservation"]
        self.assertEqual(file["drive_file_id"], "reserved-id")
        self.assertNotIn("lease_token", self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
            self.payload, "approved-session")["reservation"])

    def test_wrong_company_workspace_account_and_role_are_rejected(self):
        variants = [
            {**self.payload, "companyID": str(uuid.uuid4())},
            {**self.payload, "replicaID": str(uuid.uuid4())},
            {**self.payload, "cloudAccountHash": "wrong"},
            {**self.payload, "grantID": str(uuid.uuid4())},
        ]
        for variant in variants:
            with self.assertRaises((RouteFailure, google_connections.ConnectionError)):
                self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                     variant, "approved-session")
        with self.assertRaises(google_connections.ConnectionError):
            self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
                                 self.payload, "wrong-session")
        self.google.role = "Accounting"
        with self.assertRaises(RouteFailure):
            self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
                                 self.payload, "approved-session")
        with self.database() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM billing_pdf_archive_intents").fetchone()[0], 0)

    def test_provider_confirmation_fails_closed_until_readback_exists(self):
        reservation = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                           self.payload, "approved-session")["reservation"]
        with self.assertRaises(RouteFailure) as failure:
            self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/confirm",
                {**self.payload, "leaseToken": reservation["lease_token"],
                 "fileID": "claimed", "contentDigest": "b" * 64}, "approved-session")
        self.assertEqual(failure.exception.code, "provider_verification_required")
        self.assertIsNone(self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
            self.payload, "approved-session")["reservation"]["confirmed_link"])

    def test_replacement_google_subject_cannot_adopt_prior_file_reservation(self):
        first = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                     self.payload, "approved-session")["reservation"]
        replacement_grant = str(uuid.uuid4())
        with self.database() as connection:
            connection.execute("UPDATE google_connections SET id=?, subject=? WHERE company_id=?",
                               (replacement_grant, "google-subject-2", self.company))
            connection.execute("UPDATE google_account_bindings SET subject=? WHERE company_id=?",
                               ("google-subject-2", self.company))
        replacement = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
            {**self.payload, "grantID": replacement_grant}, "approved-session")["reservation"]
        self.assertNotEqual(replacement["key"]["drive_account"], first["key"]["drive_account"])
        self.assertNotEqual(replacement["attachment_id"], first["attachment_id"])
        self.assertIsNone(replacement["drive_file_id"])
        with self.assertRaises(google_connections.ConnectionError):
            self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
                                 self.payload, "approved-session")


if __name__ == "__main__":
    unittest.main()
