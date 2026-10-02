import unittest

from Backend.billing_pdf_archive_routes import RouteFailure
from Backend.billing_pdf_drive_upload import ProviderUploadError
from Backend.test_billing_pdf_archive_routes import BillingPDFArchiveRoutesTests, FakeReadback


class FakeUploader:
    def __init__(self):
        self.generated = 0
        self.created = []
        self.fail = False

    def generate_id(self, token):
        self.generated += 1
        return "generated-file-id"

    def create(self, key, reservation, data, token):
        self.created.append((key, reservation.drive_file_id, data, token))
        if self.fail:
            raise ProviderUploadError("Uncertain provider response")
        return reservation.drive_file_id


class DeliveryRouteTests(unittest.TestCase):
    database = BillingPDFArchiveRoutesTests.database
    def setUp(self):
        BillingPDFArchiveRoutesTests.setUp(self)
        self.uploader = FakeUploader()
        self.routes.uploader = self.uploader
        self.routes.readback = FakeReadback(succeeds=True)

    def reserve_and_retain(self):
        reservation = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
            self.payload, "approved-session")["reservation"]
        BillingPDFArchiveRoutesTests.retained(self, reservation)
        return reservation

    def deliver(self, reservation, *, session="approved-session"):
        return self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/deliver",
            {**self.payload, "leaseToken": reservation["lease_token"], "contentDigest": self.digest},
            session)["reservation"]

    def test_retained_pdf_is_created_once_and_only_exact_readback_confirms(self):
        reservation = self.reserve_and_retain()
        delivered = self.deliver(reservation)
        self.assertEqual(delivered["drive_file_id"], "generated-file-id")
        self.assertEqual(delivered["confirmed_link"],
            "https://drive.google.com/file/d/generated-file-id/view")
        self.assertEqual((self.uploader.generated, len(self.uploader.created), self.routes.readback.calls), (1, 1, 1))
        self.assertEqual(self.uploader.created[0][2], self.pdf)
        repeated = self.deliver(reservation)
        self.assertEqual(repeated["confirmed_link"], delivered["confirmed_link"])
        self.assertEqual((self.uploader.generated, len(self.uploader.created)), (1, 1))

    def test_uncertain_upload_keeps_original_id_and_retry_uses_it(self):
        reservation = self.reserve_and_retain()
        self.uploader.fail = True
        with self.assertRaises(RouteFailure) as failure:
            self.deliver(reservation)
        self.assertEqual(failure.exception.code, "provider_unconfirmed")
        pending = self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
            self.payload, "approved-session")["reservation"]
        self.assertEqual(pending["drive_file_id"], "generated-file-id")
        self.assertIsNone(pending["confirmed_link"])
        self.uploader.fail = False
        self.assertEqual(self.deliver(reservation)["drive_file_id"], "generated-file-id")
        self.assertEqual((self.uploader.generated, len(self.uploader.created)), (1, 2))

    def test_missing_artifact_and_wrong_session_refuse_before_provider(self):
        reservation = self.routes.dispatch("POST", "/api/google/drive/billing-pdf-intents/reserve",
            self.payload, "approved-session")["reservation"]
        with self.assertRaises(RouteFailure):
            self.deliver(reservation)
        self.assertEqual(self.uploader.generated, 0)
        BillingPDFArchiveRoutesTests.retained(self, reservation)
        with self.assertRaises(Exception):
            self.deliver(reservation, session="wrong-session")
        self.assertEqual(self.uploader.generated, 0)

    def test_changed_account_refuses_before_post(self):
        reservation = self.reserve_and_retain()
        original = self.uploader.generate_id
        def changed(token):
            result = original(token)
            with self.database() as connection:
                connection.execute("UPDATE google_connections SET subject=?", ("different",))
            return result
        self.uploader.generate_id = changed
        with self.assertRaises(RouteFailure) as failure:
            self.deliver(reservation)
        self.assertEqual(failure.exception.code, "account_changed")
        self.assertEqual(self.uploader.created, [])

    def test_unconfirmed_readback_keeps_id_without_confirming(self):
        reservation = self.reserve_and_retain()
        self.routes.readback = FakeReadback(succeeds=False)
        with self.assertRaises(RouteFailure) as failure:
            self.deliver(reservation)
        self.assertEqual(failure.exception.code, "provider_unconfirmed")
        pending = self.routes.dispatch("GET", "/api/google/drive/billing-pdf-intents",
            self.payload, "approved-session")["reservation"]
        self.assertEqual(pending["drive_file_id"], "generated-file-id")
        self.assertIsNone(pending["confirmed_link"])


if __name__ == "__main__":
    unittest.main()
