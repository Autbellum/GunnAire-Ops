from pathlib import Path
import hashlib
import sqlite3
import tempfile
import unittest
import uuid

from Backend import google_connections
from Backend.billing_pdf_archive_ledger import BillingPDFArchiveLedger
from Backend.billing_pdf_archive_routes import BillingPDFArchiveRoutes, RouteFailure
from Backend.billing_pdf_drive_readback import ProviderReadbackError
from Backend.billing_pdf_artifacts import BillingPDFArtifactStore


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

    def access(self, session_id, company, grant_id, scopes):
        if session_id != "approved-session":
            raise google_connections.ConnectionError("access_required", "Sign in again.", 403)
        return "fixture-access-token"


class FakeReadback:
    def __init__(self, *, succeeds=False):
        self.succeeds = succeeds
        self.calls = 0

    def verify(self, key, reservation, access_token):
        self.calls += 1
        if not self.succeeds:
            raise ProviderReadbackError("Drive PDF revision was not verified")
        if access_token != "fixture-access-token":
            raise ProviderReadbackError("Wrong Google grant")
        return "https://drive.google.com/file/d/" + reservation.drive_file_id + "/view"


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
            ledger=self.ledger, readback=FakeReadback(),
            artifacts=BillingPDFArtifactStore(Path(self.temporary.name) / "storage"))
        self.payload = {
            "companyID": self.company, "grantID": self.grant,
            "containerID": "iCloud.com.gunnaire.businesssuite", "environment": "production",
            "replicaID": self.replica, "cloudAccountHash": "account-hash",
            "expectedDriveAccount": "google-subject:" + hashlib.sha256(self.subject.encode()).hexdigest(),
            "documentKind": "invoice", "documentID": self.document,
            "sourceDigest": "a" * 64, "rendererVersion": "customer-pdf-v1",
        }
        self.pdf = b"%PDF-1.7\ncustomer revision\n%%EOF\n"
        self.digest = hashlib.sha256(self.pdf).hexdigest()

    def retained(self, reservation):
        return self.routes.artifact("POST", {**self.payload,
            "leaseToken": reservation["lease_token"], "contentDigest": self.digest},
            "approved-session", self.pdf)["reservation"]

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
        content = self.retained(original)
        self.assertEqual(content["content_digest"], self.digest)
        file = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/file",
            {**self.payload, "leaseToken": original["lease_token"], "fileID": "reserved-id"},
            "approved-session")["reservation"]
        self.assertEqual(file["drive_file_id"], "reserved-id")
        self.assertNotIn("lease_token", self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
            self.payload, "approved-session")["reservation"])

    def test_read_only_identity_preflight_binds_original_google_subject(self):
        identity = self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents/identity",
            {key: value for key, value in self.payload.items() if key not in
             {"expectedDriveAccount", "documentKind", "documentID", "sourceDigest", "rendererVersion"}}, "approved-session")
        self.assertEqual(identity, {
            "companyID": self.company,
            "grantID": self.grant,
            "driveAccount": "google-subject:" + hashlib.sha256(self.subject.encode()).hexdigest(),
        })
        with self.database() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM billing_pdf_archive_intents").fetchone()[0], 0)
        with self.assertRaises(RouteFailure):
            self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents/identity",
                {**self.payload}, "approved-session")

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

    def test_provider_confirmation_fails_closed_when_readback_rejects(self):
        reservation = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                           self.payload, "approved-session")["reservation"]
        self.retained(reservation)
        self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/file",
            {**self.payload, "leaseToken": reservation["lease_token"], "fileID": "claimed"},
            "approved-session")
        with self.assertRaises(RouteFailure) as failure:
            self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/confirm",
                {**self.payload, "leaseToken": reservation["lease_token"],
                 "fileID": "claimed", "contentDigest": self.digest}, "approved-session")
        self.assertEqual(failure.exception.code, "provider_unconfirmed")
        self.assertIsNone(self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
            self.payload, "approved-session")["reservation"]["confirmed_link"])

    def test_confirm_requires_readback_and_closes_original_lease(self):
        reservation = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                           self.payload, "approved-session")["reservation"]
        self.retained(reservation)
        self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/file",
            {**self.payload, "leaseToken": reservation["lease_token"], "fileID": "claimed"},
            "approved-session")
        self.routes.readback = FakeReadback(succeeds=True)
        confirmed = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/confirm",
            {**self.payload, "leaseToken": reservation["lease_token"],
             "fileID": "claimed", "contentDigest": self.digest}, "approved-session")["reservation"]
        self.assertEqual(confirmed["confirmed_link"], "https://drive.google.com/file/d/claimed/view")
        self.assertNotIn("lease_token", confirmed)
        self.assertEqual(self.routes.readback.calls, 1)
        with self.assertRaises(RouteFailure) as failure:
            self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/confirm",
                {**self.payload, "leaseToken": reservation["lease_token"],
                 "fileID": "claimed", "contentDigest": self.digest}, "approved-session")
        self.assertEqual(failure.exception.code, "reservation_changed")
        self.assertEqual(self.routes.readback.calls, 1)

    def test_wrong_confirm_digest_does_not_bind_a_file_id(self):
        reservation = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                           self.payload, "approved-session")["reservation"]
        self.retained(reservation)
        with self.assertRaises(RouteFailure) as failure:
            self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/confirm",
                {**self.payload, "leaseToken": reservation["lease_token"],
                 "fileID": "wrong-file-id", "contentDigest": "c" * 64}, "approved-session")
        self.assertEqual(failure.exception.code, "reservation_changed")
        status = self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
                                      self.payload, "approved-session")["reservation"]
        self.assertIsNone(status["drive_file_id"])
        self.assertEqual(self.routes.readback.calls, 0)

    def test_confirm_cannot_introduce_a_file_id_without_prior_binding(self):
        reservation = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                           self.payload, "approved-session")["reservation"]
        self.retained(reservation)
        with self.assertRaises(RouteFailure) as failure:
            self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/confirm",
                {**self.payload, "leaseToken": reservation["lease_token"],
                 "fileID": "unbound-file", "contentDigest": self.digest}, "approved-session")
        self.assertEqual(failure.exception.code, "reservation_changed")
        with self.database() as connection:
            self.assertIsNone(connection.execute(
                "SELECT drive_file_id FROM billing_pdf_archive_intents WHERE attachment_id=?",
                (reservation["attachment_id"],)).fetchone()[0])
        self.assertEqual(self.routes.readback.calls, 0)

    def test_google_grant_change_during_readback_cannot_confirm(self):
        reservation = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                           self.payload, "approved-session")["reservation"]
        self.retained(reservation)
        self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/file",
            {**self.payload, "leaseToken": reservation["lease_token"], "fileID": "claimed"},
            "approved-session")

        class ReconnectDuringReadback:
            def verify(inner, key, saved, token):
                with self.database() as connection:
                    connection.execute("UPDATE google_connections SET subject=? WHERE company_id=?",
                                       ("replacement-google-subject", self.company))
                    connection.execute("UPDATE google_account_bindings SET subject=? WHERE company_id=?",
                                       ("replacement-google-subject", self.company))
                return "https://drive.google.com/file/d/claimed/view"

        self.routes.readback = ReconnectDuringReadback()
        with self.assertRaises(RouteFailure) as failure:
            self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/confirm",
                {**self.payload, "leaseToken": reservation["lease_token"],
                 "fileID": "claimed", "contentDigest": self.digest}, "approved-session")
        self.assertEqual(failure.exception.code, "account_changed")
        with self.database() as connection:
            self.assertIsNone(connection.execute(
                "SELECT confirmed_link FROM billing_pdf_archive_intents WHERE drive_file_id=?",
                ("claimed",)).fetchone()[0])

    def test_replacement_google_subject_cannot_adopt_prior_file_reservation(self):
        first = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                     self.payload, "approved-session")["reservation"]
        replacement_grant = str(uuid.uuid4())
        with self.database() as connection:
            connection.execute("UPDATE google_connections SET id=?, subject=? WHERE company_id=?",
                               (replacement_grant, "google-subject-2", self.company))
            connection.execute("UPDATE google_account_bindings SET subject=? WHERE company_id=?",
                               ("google-subject-2", self.company))
        with self.assertRaises(RouteFailure) as mismatch:
            self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                {**self.payload, "grantID": replacement_grant}, "approved-session")
        self.assertEqual(mismatch.exception.code, "account_changed")
        with self.database() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM billing_pdf_archive_intents").fetchone()[0], 1)
        replacement = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
            {**self.payload, "grantID": replacement_grant,
             "expectedDriveAccount": "google-subject:" + hashlib.sha256(b"google-subject-2").hexdigest()},
            "approved-session")["reservation"]
        self.assertNotEqual(replacement["key"]["drive_account"], first["key"]["drive_account"])
        self.assertNotEqual(replacement["attachment_id"], first["attachment_id"])
        self.assertIsNone(replacement["drive_file_id"])
        with self.assertRaises(google_connections.ConnectionError):
            self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
                                 self.payload, "approved-session")

    def test_server_artifact_is_one_immutable_pdf_across_devices(self):
        pdf = b"%PDF-1.7\ncustomer revision\n%%EOF\n"
        digest = hashlib.sha256(pdf).hexdigest()
        first = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                     self.payload, "approved-session")["reservation"]
        posted = self.routes.artifact("POST", {**self.payload,
            "leaseToken": first["lease_token"], "contentDigest": digest}, "approved-session", pdf)
        self.assertEqual(posted["artifact"], {"fileSizeBytes": len(pdf), "fileSHA256": digest})
        self.assertEqual(self.routes.artifact("GET", self.payload, "approved-session"), pdf)
        again = self.routes.artifact("POST", {**self.payload,
            "leaseToken": first["lease_token"], "contentDigest": digest}, "approved-session", pdf)
        self.assertEqual(again["reservation"]["attachment_id"], first["attachment_id"])
        self.assertEqual(len(list((Path(self.temporary.name) / "storage").rglob("*.pdf"))), 1)
        with self.assertRaises(RouteFailure):
            self.routes.artifact("POST", {**self.payload,
                "leaseToken": first["lease_token"], "contentDigest": digest},
                "approved-session", b"%PDF-1.7\nchanged\n")
        self.assertEqual(self.routes.artifact("GET", self.payload, "approved-session"), pdf)

    def test_artifact_requires_current_account_workspace_and_lease(self):
        pdf = b"%PDF-1.7\ncustomer revision\n%%EOF\n"
        digest = hashlib.sha256(pdf).hexdigest()
        first = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                     self.payload, "approved-session")["reservation"]
        with self.assertRaises(RouteFailure):
            self.routes.artifact("POST", {**self.payload,
                "leaseToken": str(uuid.uuid4()), "contentDigest": digest}, "approved-session", pdf)
        with self.assertRaises(RouteFailure):
            self.routes.artifact("POST", {**self.payload, "replicaID": str(uuid.uuid4()),
                "leaseToken": first["lease_token"], "contentDigest": digest}, "approved-session", pdf)
        with self.assertRaises(google_connections.ConnectionError):
            self.routes.artifact("GET", self.payload, "wrong-session")
        self.assertEqual(len(list((Path(self.temporary.name) / "storage").rglob("*.pdf"))), 0)

    def test_reconnected_google_account_cannot_read_prior_artifact(self):
        pdf = b"%PDF-1.7\ncustomer revision\n%%EOF\n"
        digest = hashlib.sha256(pdf).hexdigest()
        first = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                     self.payload, "approved-session")["reservation"]
        self.routes.artifact("POST", {**self.payload, "leaseToken": first["lease_token"],
            "contentDigest": digest}, "approved-session", pdf)
        with self.database() as connection:
            connection.execute("UPDATE google_connections SET subject=? WHERE company_id=?",
                               ("replacement-subject", self.company))
            connection.execute("UPDATE google_account_bindings SET subject=? WHERE company_id=?",
                               ("replacement-subject", self.company))
        with self.assertRaises(RouteFailure) as failure:
            self.routes.artifact("GET", self.payload, "approved-session")
        self.assertEqual(failure.exception.code, "account_changed")

    def test_storage_failure_preserves_digest_for_exact_retry(self):
        pdf = b"%PDF-1.7\ncustomer revision\n%%EOF\n"
        digest = hashlib.sha256(pdf).hexdigest()
        first = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
                                     self.payload, "approved-session")["reservation"]
        storage = Path(self.temporary.name) / "storage"
        storage.write_bytes(b"storage temporarily unavailable")
        fields = {**self.payload, "leaseToken": first["lease_token"], "contentDigest": digest}
        with self.assertRaises(RouteFailure) as failure:
            self.routes.artifact("POST", fields, "approved-session", pdf)
        self.assertEqual(failure.exception.code, "artifact_unavailable")
        status = self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
                                      self.payload, "approved-session")["reservation"]
        self.assertEqual(status["content_digest"], digest)
        self.assertFalse(status["artifact_ready"])
        storage.unlink()
        saved = self.routes.artifact("POST", fields, "approved-session", pdf)["reservation"]
        self.assertTrue(saved["artifact_ready"])
        self.assertEqual(saved["artifact_bytes"], len(pdf))
        self.assertEqual(self.routes.artifact("GET", self.payload, "approved-session"), pdf)


if __name__ == "__main__":
    unittest.main()
