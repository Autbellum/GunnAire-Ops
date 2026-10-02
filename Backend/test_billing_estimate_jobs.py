from __future__ import annotations

import unittest
import sqlite3
from datetime import datetime, timedelta, timezone

from Backend import billing_estimate_jobs as jobs
from Backend import billing_publications as billing
from Backend import billing_provider
from Backend import gunnaire_backend as backend
from Backend import test_billing_assignments as assignment_fixtures
from Backend.test_billing_publications import BillingFixture


class EstimateJobTests(BillingFixture, unittest.TestCase):
    http = assignment_fixtures.BillingAssignmentTests.http

    def setUp(self):
        super().setUp()
        self.time = datetime(2026, 10, 2, 3, tzinfo=timezone.utc)
        self.queue = jobs.EstimateJobs(backend.db, self.publisher, now=lambda: self.time)

    def test_enqueue_is_durable_and_replay_runs_one_original_create(self):
        first = self.queue.enqueue(self.admin, self.estimate())
        second = self.queue.enqueue(self.admin, self.estimate())
        self.assertEqual(first["publication"]["id"], second["publication"]["id"])
        self.assertEqual(first["background"]["state"], "pending")
        self.assertEqual(self.writes, [])
        self.assertTrue(self.queue.run_one())
        self.assertFalse(self.queue.run_one())
        confirmed = self.queue.status(self.admin, first["publication"]["id"])
        self.assertEqual(confirmed["publication"]["state"], "confirmed")
        self.assertEqual(confirmed["background"]["state"], "confirmed")
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.writes[0][0], "Estimate")

    def test_failed_job_insert_rolls_back_original_reservation(self):
        with backend.db() as connection:
            connection.execute("""CREATE TRIGGER reject_estimate_job BEFORE INSERT ON billing_estimate_jobs
                BEGIN SELECT RAISE(FAIL, 'fixture rejects insert'); END""")
        with self.assertRaises(sqlite3.Error):
            self.queue.enqueue(self.admin, self.estimate())
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM billing_publications").fetchone()[0], 0)
            self.assertEqual(connection.execute("SELECT count(*) FROM billing_estimate_jobs").fetchone()[0], 0)
        self.assertEqual(self.writes, [])

    def test_lost_response_and_expired_lease_reconcile_without_second_post(self):
        queued = self.queue.enqueue(self.admin, self.estimate())
        publication_id = queued["publication"]["id"]
        self.after_write = lambda _: (_ for _ in ()).throw(
            billing.failure("provider_unavailable", "Fixture response was lost."))
        self.assertTrue(self.queue.run_one())
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(self.row()["state"], "unknown")
        self.assertEqual(self.queue.status(self.admin, publication_id)["background"]["state"], "pending")
        self.time += timedelta(minutes=5)
        restarted = jobs.EstimateJobs(backend.db, self.publisher, now=lambda: self.time)
        self.assertTrue(restarted.run_one())
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(restarted.status(self.admin, publication_id)["background"]["state"], "confirmed")

    def test_crash_after_send_permit_is_consumed_never_creates_a_second_estimate(self):
        queued = self.queue.enqueue(self.admin, self.estimate())
        self.publisher.claim(self.admin, queued["publication"]["id"])
        self.assertEqual(self.row()["state"], "sending")
        self.assertTrue(self.queue.run_one())
        self.assertEqual(self.writes, [])
        self.assertEqual(self.row()["state"], "sending")
        self.assertEqual(self.queue.status(self.admin, queued["publication"]["id"])["background"]["state"], "pending")

    def test_replay_preserves_retry_delay(self):
        queued = self.queue.enqueue(self.admin, self.estimate())
        self.before_read = lambda: (_ for _ in ()).throw(
            billing.failure("provider_unavailable", "Fixture census unavailable."))
        self.assertTrue(self.queue.run_one())
        original = self.queue.status(self.admin, queued["publication"]["id"])["background"]
        self.assertEqual(original["state"], "pending")
        self.queue.enqueue(self.admin, self.estimate())
        self.assertIsNone(self.queue.claim_one())
        self.time += timedelta(minutes=5)
        self.assertIsNotNone(self.queue.claim_one())
        self.assertEqual(self.writes, [])

    def assert_job_stops_for_review(self, publication_id):
        self.assertTrue(self.queue.run_one())
        self.assertEqual(self.writes, [])
        with backend.db() as connection:
            row = connection.execute("SELECT state FROM billing_estimate_jobs WHERE publication_id=?",
                (publication_id,)).fetchone()
        self.assertEqual(row["state"], "review")

    def test_revoked_session_never_posts(self):
        queued = self.queue.enqueue(self.admin, self.estimate())
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE id=?", (backend.utc_now(), self.admin))
        self.assert_job_stops_for_review(queued["publication"]["id"])

    def test_expired_session_never_posts(self):
        queued = self.queue.enqueue(self.admin, self.estimate())
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET expires_at='2020-01-01T00:00:00+00:00' WHERE id=?", (self.admin,))
        self.assert_job_stops_for_review(queued["publication"]["id"])

    def test_removed_office_role_never_posts(self):
        queued = self.queue.enqueue(self.admin, self.estimate())
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard' WHERE email=?", (self.email("Admin"),))
        self.assert_job_stops_for_review(queued["publication"]["id"])

    def test_changed_quickbooks_realm_never_posts(self):
        queued = self.queue.enqueue(self.admin, self.estimate())
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET realm_id='other-realm' WHERE id=1")
        self.assert_job_stops_for_review(queued["publication"]["id"])

    def test_changed_grant_never_posts(self):
        queued = self.queue.enqueue(self.admin, self.estimate())
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='replacement' WHERE id=1")
        self.assert_job_stops_for_review(queued["publication"]["id"])

    def test_invoice_and_estimate_update_cannot_enter_background_queue(self):
        self.expect("invalid_action", lambda: self.queue.enqueue(self.admin, self.payload()))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM billing_publications").fetchone()[0], 0)
        update = self.estimate()
        update["operation"] = "update"
        update["document"].update(Id="D1", SyncToken="0", sparse=True)
        self.expect("invalid_request", lambda: self.queue.enqueue(self.admin, update))
        self.assertEqual(self.writes, [])

    def test_enqueued_running_lease_cannot_be_stolen_early_and_can_be_recovered(self):
        queued = self.queue.enqueue(self.admin, self.estimate())
        claimed = self.queue.claim_one()
        self.assertIsNotNone(claimed)
        self.assertIsNone(self.queue.claim_one())
        self.time += timedelta(hours=1, seconds=1)
        recovered = self.queue.claim_one()
        self.assertEqual(recovered["publication_id"], queued["publication"]["id"])
        self.assertNotEqual(recovered["lease_id"], claimed["lease_id"])
        self.assertFalse(self.queue.finish(claimed, confirmed=True))
        self.assertTrue(self.queue.finish(recovered, error_code="provider_unavailable"))

    def test_provider_census_cap_stops_before_write(self):
        requests = []

        def send(request):
            requests.append(request)
            return {"QueryResponse": {"totalCount": 501}}

        provider = billing_provider.BillingQBOProvider(
            {"realm_id": "realm", "environment": "sandbox"}, lambda: None,
            lambda *_: "fixture-token", send=send, maximum_documents=500)
        with self.assertRaises(billing.AttemptError) as caught:
            provider.documents("Estimate")
        self.assertEqual(caught.exception.code, "background_census_limit")
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].get_method(), "GET")

    def test_http_enqueue_returns_pending_and_never_calls_qbo(self):
        with self.http() as request:
            status, queued = request("/api/billing-publications/background-estimate", self.estimate())
            self.assertEqual(status, 200, queued)
            self.assertEqual(queued["background"]["state"], "pending")
            identifier = queued["publication"]["id"]
            self.assertEqual(request("/api/billing-publications/background-estimate/" + identifier)[1]["background"]["state"], "pending")
            self.assertEqual(request("/api/billing-publications/background-estimate", self.payload())[0], 400)
            self.assertEqual(request("/api/billing-publications/background-estimate", self.estimate(), "Standard")[0], 403)
        self.assertEqual(self.writes, [])


if __name__ == "__main__":
    unittest.main()
