from __future__ import annotations

import copy
import json
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import time_publications as times
from Backend import test_time_worker_mappings as worker_fixtures


class TimePublicationTests(unittest.TestCase):
    context = worker_fixtures.TimeWorkerMappingTests.context
    expect = worker_fixtures.TimeWorkerMappingTests.expect
    change = worker_fixtures.TimeWorkerMappingTests.change

    def setUp(self):
        worker_fixtures.TimeWorkerMappingTests.setUp(self)
        self.service.save(self.admin, worker_fixtures.TimeWorkerMappingTests.payload(self))
        self.records, self.posts, self.provider_reads = [], [], []
        self.before_query = self.after_query = self.before_create = self.after_create = self.before_reference = lambda: None
        self.now = datetime.now(timezone.utc)
        self.customer, self.item, self.job = (str(uuid.uuid4()) for _ in range(3))
        fixture = self

        class Provider:
            def __init__(self, context, authorize, bearer_loader=None):
                self.authorize = authorize

            def read(self, kind, identifier):
                self.authorize()
                fixture.provider_reads.append((kind, identifier))
                fixture.before_reference()
                self.authorize()
                if kind in ("Employee", "Vendor"):
                    return copy.deepcopy(fixture.remote)
                return {"Id": identifier, "Active": True, "Type": "Service", "DisplayName": "Private customer fixture"}

            def activities(self):
                self.authorize()
                fixture.before_query()
                values = copy.deepcopy(fixture.records)
                fixture.after_query()
                self.authorize()
                return values

            def create(self, document, request_id):
                self.authorize()
                fixture.before_create()
                self.authorize()
                fixture.posts.append((copy.deepcopy(document), request_id))
                result = {**copy.deepcopy(document), "Id": "800", "SyncToken": "0", "HourlyRate": 999, "CostRate": 777}
                fixture.records.append(result)
                fixture.after_create()
                self.authorize()
                return copy.deepcopy(result)

        self.publication_provider = mock.patch.object(backend, "TimeQBOProvider", Provider)
        self.publication_provider.start()
        self.publisher = times.TimePublisher(backend.db, Provider, lambda grant, authorize: None,
            backend.encrypt_catalog_payload, backend.decrypt_catalog_payload, backend.record_audit_event, lambda: self.now)

    def tearDown(self):
        self.publication_provider.stop()
        worker_fixtures.TimeWorkerMappingTests.tearDown(self)

    def payload(self, **changes):
        context = self.context()
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox", "connectionRevision": context["connectionRevision"],
                "localEntryID": str(uuid.uuid4()), "workerEmail": self.worker, "mappingRevision": 1,
                "entryRevision": "a" * 64, "clockIn": (self.now - timedelta(hours=3)).isoformat(),
                "clockOut": (self.now - timedelta(hours=1)).isoformat(), "timeZone": "America/New_York", "payableMinutes": 120,
                "activity": "general", "notes": "Completed approved training", "serviceCallID": None, "localCustomerID": None,
                "localItemID": None, "reviewedByEmail": "accounting@example.invalid", "reviewedAt": self.now.isoformat(), **changes}

    def prepare(self, **changes):
        return self.publisher.prepare(self.admin, self.payload(**changes))["publication"]

    def decision(self, publication, **changes):
        return {"companyID": self.company, "entryRevision": publication["entryRevision"], "reviewHash": publication["reviewHash"], **changes}

    def confirm(self, publication):
        return self.publisher.decision(self.admin, publication["id"], self.decision(publication))["publication"]

    def cancel(self, publication):
        return self.publisher.cancel(self.admin, publication["id"], {"companyID": self.company, "reviewHash": publication["reviewHash"]})["publication"]

    def state(self, publication):
        with backend.db() as connection:
            return dict(self.publisher.record(connection, publication["id"]))

    def reconnect(self):
        self.change("UPDATE qbo_connections SET authorized_at='new-grant'")

    def legacy(self, publication, **changes):
        return {**publication["timeActivity"], "Description": "Legacy office-approved note\n" + times.marker(publication["localEntryID"]),
                "Id": "legacy", "SyncToken": "2", **changes}

    def seed_job(self):
        self.change("INSERT INTO customer_entity_mappings VALUES (?,?,?,?,?)", (self.company, "realm", "sandbox", self.customer, "C55"))
        self.change("INSERT INTO catalog_entity_mappings VALUES (?,?,?,?,?)", (self.company, "realm", "sandbox", self.item, "I55"))
        self.change("INSERT INTO billing_job_assignments VALUES (?,?,?,?,?,1,'cipher','hash',0,'old-grant','dispatcher@example.invalid','old')",
                    (self.company, "realm", "sandbox", self.job, self.customer))

    def test_preparation_only_reads_and_encrypts_source_evidence(self):
        publication = self.prepare()
        self.assertEqual(publication["state"], "reserved")
        self.assertIsNone(publication["receipt"])
        self.assertFalse(self.posts)
        self.assertEqual(self.provider_reads, [("Employee", "55")])
        row = self.state(publication)
        self.assertNotIn("Completed approved training", row["payload_ciphertext"])
        self.assertNotIn("SSN", json.dumps(publication))
        self.assertEqual(publication["timeActivity"]["Hours"], 2)
        self.assertEqual(publication["timeActivity"]["Minutes"], 0)
        self.assertIn(times.marker(publication["localEntryID"]), publication["timeActivity"]["Description"])

    def test_confirm_records_one_approval_and_dispatch_and_exact_original_receipt(self):
        publication = self.prepare()
        result = self.confirm(publication)
        self.assertEqual(result["state"], "confirmed")
        self.assertEqual(result["receipt"]["providerID"], "800")
        self.assertFalse(result["receipt"]["legacyAdoption"])
        self.assertEqual(len(self.posts), 1)
        self.assertEqual(self.posts[0][0], publication["timeActivity"])
        with backend.db() as connection:
            actions = [row[0] for row in connection.execute("SELECT action FROM audit_events WHERE subject_type='time-publication' ORDER BY occurred_at")]
        self.assertEqual(actions, ["prepare", "approve-and-dispatch", "confirm"])
        for value in ("HourlyRate", "CostRate", "SSN", "private-fixture", "grant_fingerprint"):
            self.assertNotIn(value, json.dumps(result))

    def test_confirm_replay_and_recovery_never_send_again(self):
        publication = self.prepare()
        first = self.confirm(publication)
        self.assertEqual(self.confirm(publication), first)
        self.assertEqual(self.publisher.recover(self.admin, publication["id"])["publication"], first)
        self.assertEqual(len(self.posts), 1)

    def test_lost_post_reply_recovers_exact_record_after_relaunch_without_resend(self):
        publication = self.prepare()
        self.after_create = lambda: (_ for _ in ()).throw(TimeoutError("fixture lost reply"))
        with self.assertRaises(TimeoutError):
            self.confirm(publication)
        self.assertEqual(self.state(publication)["state"], "unknown")
        self.after_create = lambda: None
        restarted = times.TimePublisher(backend.db, self.publisher.provider_factory, lambda a, b: None,
            backend.encrypt_catalog_payload, backend.decrypt_catalog_payload, backend.record_audit_event)
        result = restarted.recover(self.admin, publication["id"])["publication"]
        self.assertEqual(result["state"], "confirmed")
        self.assertEqual(len(self.posts), 1)

    def test_crash_after_claim_and_empty_recovery_does_not_send_or_cancel(self):
        publication = self.prepare()
        self.change("UPDATE time_publications SET state='sending' WHERE id=?", (publication["id"],))
        self.assertEqual(self.confirm(publication)["state"], "sending")
        self.expect("cannot_cancel", lambda: self.cancel(publication))
        self.assertFalse(self.posts)

    def test_unknown_cannot_be_reprepared_with_changed_values_or_another_realm(self):
        publication = self.prepare()
        self.change("UPDATE time_publications SET state='unknown' WHERE id=?", (publication["id"],))
        self.expect("publication_pending", lambda: self.publisher.prepare(self.admin, {**publication["review"], "notes": "Changed hours explanation"}))
        self.change("UPDATE qbo_connections SET realm_id='different'")
        context = self.context()
        self.expect("publication_pending", lambda: self.publisher.prepare(self.admin, {**publication["review"], "realmID": "different", "connectionRevision": context["connectionRevision"]}))

    def test_same_prepare_lost_response_returns_one_original_reservation(self):
        payload = self.payload()
        first = self.publisher.prepare(self.admin, payload)
        self.assertEqual(self.publisher.prepare(self.admin, payload), first)
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM time_publications").fetchone()[0], 1)

    def test_cancel_offline_does_not_require_provider_and_allows_corrected_review(self):
        publication = self.prepare()
        self.change("DELETE FROM qbo_connections")
        self.assertEqual(self.cancel(publication)["state"], "cancelled")
        self.assertEqual(self.cancel(publication)["state"], "cancelled")
        self.expect("provider_changed", lambda: self.publisher.recover(self.admin, publication["id"]))
        self.assertFalse(self.posts)

    def test_cancelled_entry_can_be_reprepared_with_new_revision(self):
        publication = self.prepare()
        self.cancel(publication)
        replacement = self.publisher.prepare(self.admin, {**publication["review"], "entryRevision": "b" * 64, "notes": "Corrected source note"})["publication"]
        self.assertNotEqual(replacement["id"], publication["id"])
        self.assertEqual(replacement["state"], "reserved")

    def test_changed_native_revision_or_review_hash_cannot_dispatch(self):
        publication = self.prepare()
        for change in ({"entryRevision": "b" * 64}, {"reviewHash": "b" * 64}, {"companyID": str(uuid.uuid4())}):
            self.expect("review_changed", lambda: self.publisher.decision(self.admin, publication["id"], self.decision(publication, **change)))
        self.assertFalse(self.posts)

    def test_wrong_office_actor_cannot_send_but_can_recover_original_receipt(self):
        publication = self.prepare()
        self.expect("actor_changed", lambda: self.publisher.decision(self.sessions["Accounting"], publication["id"], self.decision(publication)))
        result = self.confirm(publication)
        self.assertEqual(self.publisher.recover(self.sessions["Accounting"], publication["id"])["publication"], result)

    def test_accounting_can_review_and_publish_without_admin_promotion(self):
        publication = self.publisher.prepare(self.sessions["Accounting"], self.payload())["publication"]
        result = self.publisher.decision(self.sessions["Accounting"], publication["id"], self.decision(publication))
        self.assertEqual(result["publication"]["state"], "confirmed")

    def test_field_dispatch_standard_or_expired_access_cannot_publish(self):
        payload = self.payload()
        for role in ("Dispatcher", "Field Technician", "Standard"):
            self.expect("office_required", lambda: self.publisher.prepare(self.sessions[role], payload))
        self.change("UPDATE auth_sessions SET revoked_at='revoked' WHERE id=?", (self.admin,))
        self.expect("office_required", lambda: self.publisher.prepare(self.admin, payload))

    def test_reconnection_blocks_reserved_send_but_unknown_recovers_old_immutable_values(self):
        publication = self.prepare()
        self.reconnect()
        self.expect("grant_changed", lambda: self.confirm(publication))
        self.change("UPDATE time_publications SET state='unknown' WHERE id=?", (publication["id"],))
        self.records = [{**publication["timeActivity"], "Id": "800", "SyncToken": "0"}]
        result = self.publisher.recover(self.admin, publication["id"])
        self.assertEqual(result["publication"]["receipt"]["providerID"], "800")
        self.assertFalse(self.posts)

    def test_grant_change_during_recovery_rejects_stale_snapshot(self):
        publication = self.prepare()
        self.change("UPDATE time_publications SET state='unknown' WHERE id=?", (publication["id"],))
        self.records = [{**publication["timeActivity"], "Id": "800", "SyncToken": "0"}]
        self.after_query = self.reconnect
        self.expect("grant_changed", lambda: self.publisher.recover(self.admin, publication["id"]))
        self.assertEqual(self.state(publication)["state"], "unknown")

    def test_role_revoked_during_read_prevents_claim(self):
        publication = self.prepare()
        self.after_query = lambda: self.change("UPDATE users SET is_active=0 WHERE email='admin@example.invalid'")
        self.expect("office_required", lambda: self.confirm(publication))
        self.assertEqual(self.state(publication)["state"], "reserved")
        self.assertFalse(self.posts)

    def test_role_revoked_after_post_retains_unknown_and_other_office_can_recover(self):
        publication = self.prepare()
        self.after_create = lambda: self.change("UPDATE users SET is_active=0 WHERE email='admin@example.invalid'")
        self.expect("office_required", lambda: self.confirm(publication))
        self.assertEqual(self.state(publication)["state"], "unknown")
        result = self.publisher.recover(self.sessions["Accounting"], publication["id"])
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(len(self.posts), 1)

    def test_mapping_changed_between_query_and_dispatch_does_not_retarget(self):
        publication = self.prepare()
        self.after_query = lambda: self.change("UPDATE time_worker_mappings SET grant_fingerprint='changed'")
        self.expect("mapping_changed", lambda: self.confirm(publication))
        self.assertFalse(self.posts)

    def test_provider_worker_inactive_or_changed_requires_mapping_review(self):
        publication = self.prepare()
        self.remote["Active"] = False
        self.expect("worker_unconfirmed", lambda: self.confirm(publication))
        self.remote["Active"] = True
        self.remote["SyncToken"] = "1"
        self.expect("worker_changed", lambda: self.confirm(publication))
        self.assertFalse(self.posts)

    def test_expired_review_requires_unsent_cancellation_and_new_review(self):
        publication = self.prepare()
        self.now += timedelta(minutes=16)
        self.expect("review_expired", lambda: self.confirm(publication))
        self.assertEqual(self.cancel(publication)["state"], "cancelled")

    def test_concurrent_confirm_has_at_most_one_create(self):
        publication = self.prepare()
        barrier = threading.Barrier(2)
        self.before_query = lambda: barrier.wait(timeout=10)
        def confirm():
            try:
                return self.confirm(publication)
            except times.AttemptError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: confirm(), range(2)))
        self.assertEqual(len(self.posts), 1, results)
        self.assertEqual(self.state(publication)["state"], "confirmed")

    def test_original_legacy_record_requires_explicit_exact_adoption_without_write(self):
        publication = self.prepare()
        self.records = [self.legacy(publication)]
        first = self.publisher.decision(self.admin, publication["id"], self.decision(publication))
        self.assertTrue(first["needsLegacyReview"])
        self.assertEqual(first["publication"]["state"], "reserved")
        candidate = first["legacyCandidate"]
        result = self.publisher.decision(self.admin, publication["id"], self.decision(publication,
            providerID=candidate["providerID"], candidateRevision=candidate["candidateRevision"]), adoption=True)
        self.assertTrue(result["publication"]["receipt"]["legacyAdoption"])
        self.assertFalse(self.posts)

    def test_legacy_candidate_changed_before_adoption_cannot_be_linked(self):
        publication = self.prepare()
        self.records = [self.legacy(publication)]
        candidate = self.publisher.recover(self.admin, publication["id"])["legacyCandidate"]
        self.records[0]["SyncToken"] = "3"
        self.expect("candidate_changed", lambda: self.publisher.decision(self.admin, publication["id"], self.decision(publication,
            providerID=candidate["providerID"], candidateRevision=candidate["candidateRevision"]), adoption=True))
        self.assertFalse(self.posts)

    def test_partial_lowercase_or_conflicting_marker_blocks_send(self):
        publication = self.prepare()
        for description in ("Prefix" + times.marker(publication["localEntryID"]), times.marker(publication["localEntryID"]).lower(),
                            times.marker(publication["localEntryID"]) + "\nGUNNAIRE-TIME-PUBLICATION:" + str(uuid.uuid4()).upper()):
            self.records = [self.legacy(publication, Description=description)]
            self.expect("time_identity_conflict", lambda: self.confirm(publication))
        self.assertFalse(self.posts)

    def test_duplicate_legacy_markers_or_wrong_values_block_send(self):
        publication = self.prepare()
        self.records = [self.legacy(publication), self.legacy(publication, Id="another")]
        self.expect("time_identity_conflict", lambda: self.confirm(publication))
        for field, value in (("Hours", 3), ("TxnDate", "2000-01-01"), ("EmployeeRef", {"value": "another"}), ("Minutes", False), ("PayrollItemRef", {"value": "payroll"})):
            self.records = [self.legacy(publication, **{field: value})]
            self.expect("time_values_conflict", lambda: self.confirm(publication))
        self.assertFalse(self.posts)

    def test_unknown_legacy_match_cannot_automatically_adopt_or_repeat_send(self):
        publication = self.prepare()
        self.change("UPDATE time_publications SET state='unknown' WHERE id=?", (publication["id"],))
        self.records = [self.legacy(publication)]
        result = self.publisher.recover(self.admin, publication["id"])
        self.assertEqual(result["publication"]["state"], "unknown")
        candidate = result["legacyCandidate"]
        self.expect("cannot_adopt", lambda: self.publisher.decision(self.admin, publication["id"], self.decision(publication,
            providerID=candidate["providerID"], candidateRevision=candidate["candidateRevision"]), adoption=True))
        self.assertFalse(self.posts)

    def test_job_customer_and_service_item_resolve_shared_ids_not_device_ids(self):
        self.seed_job()
        publication = self.prepare(activity="job", serviceCallID=self.job, localCustomerID=self.customer, localItemID=self.item)
        self.assertEqual(publication["timeActivity"]["CustomerRef"], {"value": "C55"})
        self.assertEqual(publication["timeActivity"]["ItemRef"], {"value": "I55"})
        self.assertEqual(self.confirm(publication)["state"], "confirmed")

    def test_changed_customer_mapping_or_job_context_requires_new_review(self):
        self.seed_job()
        publication = self.prepare(activity="job", serviceCallID=self.job, localCustomerID=self.customer)
        self.change("UPDATE customer_entity_mappings SET provider_id='changed'")
        self.expect("reference_changed", lambda: self.confirm(publication))
        self.change("UPDATE customer_entity_mappings SET provider_id='C55'")
        self.change("UPDATE billing_job_assignments SET revision=2")
        self.expect("reference_changed", lambda: self.confirm(publication))
        self.assertFalse(self.posts)

    def test_missing_job_or_shared_customer_cannot_silently_drop_job_cost_context(self):
        self.expect("invalid_time", lambda: self.prepare(activity="job"))
        self.expect("reference_missing", lambda: self.prepare(activity="job", serviceCallID=self.job, localCustomerID=self.customer))

    def test_list_is_business_scoped_offline_and_excludes_provider_secrets(self):
        publication = self.prepare()
        self.change("DELETE FROM qbo_connections")
        result = self.publisher.list_for_entry(self.sessions["Accounting"], {"companyID": self.company, "localEntryID": publication["localEntryID"]})
        self.assertEqual(len(result["publications"]), 1)
        self.expect("company_changed", lambda: self.publisher.list_for_entry(self.admin, {"companyID": str(uuid.uuid4()), "localEntryID": publication["localEntryID"]}))
        self.expect("office_required", lambda: self.publisher.list_for_entry(self.sessions["Field Technician"], {"companyID": self.company, "localEntryID": publication["localEntryID"]}))
        self.assertNotIn("grant_fingerprint", json.dumps(result))

    def test_encrypted_payload_tampering_prevents_recovery_or_send(self):
        publication = self.prepare()
        self.change("UPDATE time_publications SET payload_hash=? WHERE id=?", ("b" * 64, publication["id"]))
        self.expect("storage_unavailable", lambda: self.publisher.recover(self.admin, publication["id"]))
        self.assertFalse(self.posts)

    def test_failed_encryption_cannot_create_dispatchable_reservation(self):
        self.publisher.encrypt = lambda _: None
        self.expect("storage_unavailable", lambda: self.prepare())
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM time_publications").fetchone()[0], 0)

    def test_validate_duration_rounding_offset_and_unpaid_break_exclusion(self):
        payload = self.payload(clockIn="2026-01-01T23:59:30-05:00", clockOut="2026-01-02T00:01:00-05:00", payableMinutes=2)
        _, posting = times.validated_request(payload, self.now)
        self.assertEqual(posting, "2026-01-01")
        for changes in ({"payableMinutes": 1}, {"payableMinutes": True}, {"activity": "unpaid_break"}, {"timeZone": "not/a/zone"},
                        {"clockOut": "2026-01-01T01:00:00"}, {"clockOut": payload["clockIn"]}, {"reviewedAt": payload["clockIn"]},
                        {"notes": "GUNNAIRE-TIME:bad"}, {"notes": "a" * 3001}, {"reviewedAt": (self.now + timedelta(seconds=1)).isoformat()}):
            self.expect("invalid_time", lambda: times.validated_request({**payload, **changes}, self.now))

    def test_unknown_request_fields_cannot_inject_payroll_or_arbitrary_provider_ids(self):
        for key in ("PayrollItemRef", "projectRef", "EmployeeRef", "customerID", "approved"):
            self.expect("invalid_request", lambda: self.publisher.prepare(self.admin, {**self.payload(), key: "untrusted"}))

    def test_all_paid_hvac_activities_preserve_activity_and_source_approval_evidence(self):
        self.seed_job()
        for activity, label in times.ACTIVITIES.items():
            changes = {"activity": activity}
            if activity == "job":
                changes.update(serviceCallID=self.job, localCustomerID=self.customer)
            publication = self.prepare(**changes)
            self.assertIn("Activity: " + label, publication["timeActivity"]["Description"])
            self.assertEqual(publication["review"]["reviewedByEmail"], "accounting@example.invalid")

    def test_provider_different_values_after_create_stays_unknown_and_does_not_retry(self):
        publication = self.prepare()
        self.after_create = lambda: self.records[0].update(Hours=99)
        self.expect("provider_unconfirmed", lambda: self.confirm(publication))
        self.assertEqual(self.state(publication)["state"], "unknown")
        self.expect("time_values_conflict", lambda: self.confirm(publication))
        self.assertEqual(len(self.posts), 1)

    def test_loopback_prepare_confirm_recovery_and_strict_session_only_routes(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = "http://127.0.0.1:" + str(server.server_port)
        def request(path, payload=None, *, token=None, raw=None):
            data = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
            req = urllib.request.Request(base + path, data=data, method="POST" if data is not None else "GET",
                headers={"Authorization": "Bearer " + (token or self.tokens["Admin"]), "Content-Type": "application/json"})
            try:
                response = urllib.request.urlopen(req, timeout=5)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                return response.status, json.loads(response.read())
        try:
            root = "/api/time-publications"
            payload = self.payload()
            status, prepared = request(root, payload)
            self.assertEqual(status, 200, prepared)
            publication = prepared["publication"]
            path = root + "/" + publication["id"]
            self.assertFalse(self.posts)
            query = urllib.parse.urlencode({"companyID": self.company, "localEntryID": publication["localEntryID"]})
            self.assertEqual(request(root + "?" + query)[0], 200)
            self.assertEqual(request(root + "?" + query + "&companyID=duplicate")[0], 400)
            self.assertEqual(request(path + "/recover", {"Hours": 99})[0], 400)
            self.assertEqual(request(path + "/confirm?force=true", self.decision(publication))[0], 404)
            self.assertEqual(request(path + "/confirm/", self.decision(publication))[0], 404)
            self.assertEqual(request(root, raw=b'{"companyID":"one","companyID":"two"}')[0], 400)
            self.assertEqual(request(root, raw=b'{"Hours":NaN}')[0], 400)
            self.assertEqual(request(root, payload, token=self.tokens["Field Technician"])[0], 403)
            with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="fixture-api-key"):
                self.assertEqual(request(root, payload, token="fixture-api-key")[0], 403)
            status, confirmed = request(path + "/confirm", self.decision(publication))
            self.assertEqual(status, 200, confirmed)
            self.assertEqual(confirmed["publication"]["state"], "confirmed")
            self.assertEqual(request(path + "/recover", {})[0], 200)
            self.assertEqual(request(path + "/cancel", {"companyID": self.company, "reviewHash": publication["reviewHash"]})[0], 409)
            self.assertEqual(len(self.posts), 1)
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=5)

    def test_http_logging_does_not_expose_entry_or_worker_identifiers(self):
        handler = mock.Mock()
        handler.address_string.return_value = "127.0.0.1"
        with mock.patch("builtins.print") as logged:
            backend.GunnAireBackendHandler.log_message(handler, '"%s" %s %s',
                "GET /api/time-publications?workerEmail=private%40example.invalid&localEntryID=private-id HTTP/1.1", "200", "-")
        self.assertIn("/api/time-publications/[redacted]", str(logged.call_args))
        self.assertNotIn("private", str(logged.call_args))

    def test_existing_shared_time_link_blocks_preparation_before_any_create(self):
        payload = self.payload()
        self.change("INSERT INTO time_entity_mappings VALUES (?,?,?,?,?)", (self.company, "realm", "sandbox", payload["localEntryID"], "old"))
        self.expect("already_published", lambda: self.publisher.prepare(self.admin, payload))
        self.assertFalse(self.posts)

    def test_link_added_during_read_blocks_dispatch(self):
        publication = self.prepare()
        self.after_query = lambda: self.change("INSERT INTO time_entity_mappings VALUES (?,?,?,?,?)",
            (self.company, "realm", "sandbox", publication["localEntryID"], "old"))
        self.expect("already_published", lambda: self.confirm(publication))
        self.assertFalse(self.posts)

    def test_new_publication_marker_with_changed_notes_does_not_confirm_recovery(self):
        publication = self.prepare()
        self.change("UPDATE time_publications SET state='unknown' WHERE id=?", (publication["id"],))
        self.records = [{**publication["timeActivity"], "Id": "800", "SyncToken": "0",
                         "Description": publication["timeActivity"]["Description"].replace("Completed approved training", "Different description")}]
        self.expect("time_values_conflict", lambda: self.publisher.recover(self.admin, publication["id"]))
        self.assertFalse(self.posts)

    def test_recovery_does_not_approve_an_unsent_reserved_entry(self):
        publication = self.prepare()
        self.records = [{**publication["timeActivity"], "Id": "800", "SyncToken": "0"}]
        result = self.publisher.recover(self.admin, publication["id"])
        self.assertEqual(result["publication"]["state"], "reserved")
        self.assertIsNone(result["publication"]["receipt"])
        self.assertFalse(self.posts)

    def test_lost_confirmation_storage_recovers_without_another_provider_request(self):
        publication = self.prepare()
        original_cipher = self.publisher.cipher
        self.publisher.cipher = lambda _: (_ for _ in ()).throw(RuntimeError("fixture failed receipt storage"))
        with self.assertRaises(RuntimeError):
            self.confirm(publication)
        self.assertEqual(self.state(publication)["state"], "unknown")
        self.publisher.cipher = original_cipher
        result = self.publisher.recover(self.admin, publication["id"])
        self.assertEqual(result["publication"]["state"], "confirmed")
        self.assertEqual(len(self.posts), 1)

    def test_corrupted_receipt_is_never_reported_as_confirmed(self):
        publication = self.prepare()
        self.confirm(publication)
        self.change("UPDATE time_publications SET receipt_ciphertext=NULL WHERE id=?", (publication["id"],))
        self.expect("storage_unavailable", lambda: self.publisher.recover(self.admin, publication["id"]))

    def test_company_switch_during_reference_read_prevents_dispatch(self):
        publication = self.prepare()
        self.before_reference = lambda: self.change("UPDATE company_identity SET company_id=?", (str(uuid.uuid4()),))
        self.expect("company_changed", lambda: self.confirm(publication))
        self.assertFalse(self.posts)

    def test_vendor_worker_uses_only_vendor_reference(self):
        mapping_payload = worker_fixtures.TimeWorkerMappingTests.payload(self, kind="Vendor", expectedRevision=1)
        candidate = self.service.context(self.admin, {"companyID": self.company, "workerEmail": self.worker, "kind": "Vendor", "providerID": "55"}, candidate=True)
        mapping_payload["referenceRevision"] = candidate["candidate"]["referenceRevision"]
        self.service.save(self.admin, mapping_payload)
        publication = self.prepare(mappingRevision=2)
        self.assertEqual(publication["timeActivity"]["NameOf"], "Vendor")
        self.assertEqual(publication["timeActivity"]["VendorRef"], {"value": "55"})
        self.assertNotIn("EmployeeRef", publication["timeActivity"])
        self.assertEqual(self.confirm(publication)["state"], "confirmed")

    def test_dst_transition_uses_elapsed_minutes_and_original_business_date(self):
        request = self.payload(clockIn="2026-03-08T01:30:00-05:00", clockOut="2026-03-08T03:30:00-04:00", payableMinutes=60)
        value, posting = times.validated_request(request, self.now)
        self.assertEqual(value["payableMinutes"], 60)
        self.assertEqual(posting, "2026-03-08")


if __name__ == "__main__":
    unittest.main()
