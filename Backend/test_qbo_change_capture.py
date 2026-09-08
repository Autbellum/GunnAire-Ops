from __future__ import annotations

import copy
import io
import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from cryptography.fernet import Fernet

from Backend import gunnaire_backend as backend
from Backend import qbo_change_capture as capture


NOW = datetime(2026, 9, 8, 2, 0, tzinfo=timezone.utc)


def record(identifier="42", *, when=NOW, deleted=False, **fields):
    result = {"Id": identifier, "MetaData": {"LastUpdatedTime": capture.stamp(when)}, **fields}
    if deleted:
        result["status"] = "Deleted"
    else:
        result.setdefault("SyncToken", "1")
    return result


def cdc(records, *, entity="Item", when=NOW):
    return {"CDCResponse": [{"QueryResponse": [{entity: records, "startPosition": 1, "maxResults": len(records)}]}],
            "time": capture.stamp(when)}


class ChangeCaptureProviderTests(unittest.TestCase):
    def setUp(self):
        self.check = mock.Mock()
        self.bearer = mock.Mock(return_value="fixture-not-live")
        self.requests = []
        self.payload = cdc([record()])
        def send(request):
            self.requests.append(request)
            return copy.deepcopy(self.payload)
        self.provider = capture.ChangeCaptureQBOProvider(
            {"realm_id": "fixture", "environment": "sandbox"}, self.check, self.bearer, send)

    def test_cdc_uses_exact_entity_original_origin_and_encoded_time(self):
        values, when = self.provider.changes("Item", capture.stamp(NOW - timedelta(minutes=1)))
        self.assertEqual(values, [record()])
        self.assertEqual(when, NOW)
        request = self.requests[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertIsNone(request.data)
        self.assertEqual(urllib.parse.urlsplit(request.full_url).path, "/v3/company/fixture/cdc")
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query), {
            "entities": ["Item"], "minorversion": ["75"], "changedSince": [capture.stamp(NOW - timedelta(minutes=1))]})
        self.assertEqual(request.get_header("Authorization"), "Bearer fixture-not-live")
        self.assertEqual(self.bearer.call_count, 1)
        self.assertEqual(self.check.call_count, 3)

    def test_every_native_accounting_collection_is_supported_separately(self):
        for entity in capture.ENTITIES:
            self.payload = cdc([record()], entity=entity)
            self.assertEqual(len(self.provider.changes(entity, capture.stamp(NOW))[0]), 1)
        self.assertEqual(len(self.requests), 13)
        self.assertEqual(self.bearer.call_count, 1)

    def test_unsupported_entity_and_undated_cursor_cannot_reach_transport(self):
        for entity, since in (("TimeActivity", capture.stamp(NOW)), ("Item,Invoice", capture.stamp(NOW)),
                              ("item", capture.stamp(NOW)), ("Item", "2026-09-01"), ("Item", "2026-09-01T00:00:00")):
            with self.subTest(entity=entity, since=since), self.assertRaises(capture.AttemptError):
                self.provider.changes(entity, since)
        self.assertFalse(self.requests)

    def test_missing_wrong_faulted_repeated_or_truncated_envelopes_are_rejected(self):
        bad = [{}, {"time": capture.stamp(NOW), "CDCResponse": []}, cdc([], entity="Invoice"),
               cdc([record(), record()]), cdc([record(when=NOW - timedelta(days=2))]),
               cdc([record(when=NOW + timedelta(minutes=1))]), cdc([{"Id": "42"}])]
        bad += [{**cdc([]), "CDCResponse": [{"QueryResponse": [{"Fault": {"Error": "private fixture"}}]}]}]
        for payload in bad:
            self.payload = payload
            with self.subTest(payload=payload), self.assertRaises(capture.AttemptError):
                self.provider.changes("Item", capture.stamp(NOW - timedelta(minutes=2)))

    def test_cap_is_not_treated_as_complete_or_paginated(self):
        self.payload = cdc([record(str(index)) for index in range(1000)])
        with self.assertRaises(capture.AttemptError) as caught:
            self.provider.changes("Item", capture.stamp(NOW))
        self.assertEqual(caught.exception.code, "change_limit")
        self.assertEqual(len(self.requests), 1)

    def test_explicit_empty_and_deleted_records_are_distinct(self):
        self.payload = cdc([])
        self.assertEqual(self.provider.changes("Item", capture.stamp(NOW))[0], [])
        self.payload = cdc([record(deleted=True)])
        self.assertEqual(self.provider.changes("Item", capture.stamp(NOW))[0][0]["status"], "Deleted")
        self.payload = cdc([])
        self.payload["CDCResponse"][0]["QueryResponse"][0].pop("Item")
        self.assertEqual(self.provider.changes("Item", capture.stamp(NOW))[0], [])

    def test_sparse_invalid_status_nonfinite_and_missing_version_are_rejected(self):
        for value in (record(sparse=True), record(status="Voided"), record(UnitPrice=float("nan")),
                      {"Id": "42", "MetaData": {"LastUpdatedTime": capture.stamp(NOW)}}):
            with self.subTest(value=value), self.assertRaises(capture.AttemptError):
                capture.record_evidence(value, tombstone_allowed=True)

    def test_census_includes_inactive_lists_and_verifies_all_pages(self):
        records = [record(str(index), Active=index % 2 == 0) for index in range(201)]
        def send(request):
            self.requests.append(request)
            sql = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)["query"][0]
            self.assertIn("Active IN (true, false)", sql)
            if "COUNT(*)" in sql:
                return {"QueryResponse": {"totalCount": len(records)}, "time": capture.stamp(NOW)}
            start = int(sql.split("STARTPOSITION ")[1].split()[0])
            page = records[start-1:start+99]
            return {"QueryResponse": {"Item": page, "startPosition": start, "maxResults": len(page)}}
        self.provider.send = send
        self.assertEqual(self.provider.census("Item"), records)
        self.assertEqual(len(self.requests), 5)

    def test_census_refuses_changing_counts_incomplete_and_duplicate_pages(self):
        for group in ({"Item": [record()], "startPosition": 1, "maxResults": 1},
                      {"Item": [record(), record()], "startPosition": 1, "maxResults": 2},
                      {"Item": [record("1"), record("2")], "startPosition": 2, "maxResults": 2}):
            self.provider.send = mock.Mock(side_effect=[{"QueryResponse": {"totalCount": 2}, "time": capture.stamp(NOW)}, {"QueryResponse": group}])
            with self.assertRaises(capture.AttemptError):
                self.provider.census("Item")
        self.provider.send = mock.Mock(side_effect=[{"QueryResponse": {"totalCount": 0}, "time": capture.stamp(NOW)},
                                                   {"QueryResponse": {"totalCount": 1}, "time": capture.stamp(NOW)}])
        with self.assertRaises(capture.AttemptError):
            self.provider.census("Item")

    def test_access_loss_after_refresh_or_response_never_returns_evidence(self):
        self.bearer.side_effect = lambda *_: setattr(self.check, "side_effect", capture.failure("administrator_required", "revoked", 403)) or "fixture"
        with self.assertRaises(capture.AttemptError):
            self.provider.changes("Item", capture.stamp(NOW))
        self.assertFalse(self.requests)
        self.check.side_effect = None
        self.provider.bearer = "fixture"
        self.provider.send = lambda _: setattr(self.check, "side_effect", capture.failure("grant_changed", "changed")) or cdc([])
        with self.assertRaises(capture.AttemptError):
            self.provider.changes("Item", capture.stamp(NOW))

    def test_transport_rejects_other_origins_methods_redirects_and_payloads(self):
        bad = ["http://quickbooks.api.intuit.com/v3/company/1/cdc?minorversion=75&entities=Item&changedSince=2026-09-08T00:00:00Z",
               "https://example.invalid/v3/company/1/cdc", "https://quickbooks.api.intuit.com/v3/company/1/invoice",
               "https://quickbooks.api.intuit.com/v3/company/1/cdc?minorversion=75&entities=Item&entities=Invoice&changedSince=2026-09-08T00:00:00Z"]
        with mock.patch.object(urllib.request, "build_opener") as opener:
            for url in bad:
                with self.assertRaises(capture.AttemptError):
                    capture.transport(urllib.request.Request(url))
            opener.assert_not_called()
        self.assertIsNone(capture.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.invalid"))
        url = "https://quickbooks.api.intuit.com/v3/company/1/cdc?minorversion=75&entities=Item&changedSince=2026-09-08T00:00:00Z"
        for body in (b'{"time":"a","time":"b"}', b'{"amount":NaN}', b'[]'):
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.status, response.read.return_value = 200, body
            with mock.patch.object(urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = response
                with self.assertRaises(capture.AttemptError):
                    capture.transport(urllib.request.Request(url))
        with mock.patch.object(urllib.request, "build_opener") as opener:
            opener.return_value.open.side_effect = urllib.error.HTTPError(url, 429, "private", {}, None)
            with self.assertRaises(capture.AttemptError) as caught:
                capture.transport(urllib.request.Request(url))
            self.assertEqual(caught.exception.code, "provider_throttled")


class ChangeCaptureServiceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.settings = mock.patch.multiple(backend, DATA_ROOT=root, DB_PATH=root / "capture.sqlite3", STORAGE_ROOT=root / "files",
            AUTH_MODE="google-id-token", PRIMARY_ADMIN_EMAIL="owner@example.invalid", QBO_TOKEN_ENCRYPTION_KEY=Fernet.generate_key().decode())
        self.settings.start()
        backend.initialize_database()
        self.now = datetime.now(timezone.utc) + timedelta(seconds=1)
        self.tokens, self.sessions = {}, {}
        with backend.db() as connection:
            self.company = connection.execute("SELECT company_id FROM company_identity").fetchone()[0]
            connection.execute("INSERT INTO qbo_connections VALUES (1,'realm','cipher','sandbox','client','grant','updated')")
            for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
                email = role.lower().replace(" ", ".") + "@example.invalid"
                connection.execute("INSERT INTO users VALUES (?,?,1,?,?)", (email, role, backend.utc_now(), backend.utc_now()))
        for role in ("Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"):
            self.tokens[role] = backend.create_app_session(role.lower().replace(" ", ".") + "@example.invalid", "google", "fixture")[0]
            with backend.db() as connection:
                self.sessions[role] = connection.execute("SELECT id FROM auth_sessions WHERE token_hash=?",
                    (backend.app_session_token_hash(self.tokens[role]),)).fetchone()[0]
        self.admin = self.sessions["Admin"]
        self.census = [record(when=self.now - timedelta(days=100), Name="Private fixture service", UnitPrice=125, Active=True)]
        self.changes = [record(when=self.now, Name="Private fixture service", UnitPrice=135, Active=False, SyncToken="2")]
        self.calls = []
        self.before_census, self.before_changes = lambda: None, lambda: None
        fixture = self
        class Provider:
            def __init__(self, context, authorize):
                self.context, self.authorize = context, authorize

            def census(self, entity):
                fixture.calls.append(("census", entity))
                fixture.before_census()
                self.authorize()
                return copy.deepcopy(fixture.census)

            def changes(self, entity, since):
                fixture.calls.append(("changes", entity, since))
                fixture.before_changes()
                self.authorize()
                return copy.deepcopy(fixture.changes), fixture.now
        self.factory = Provider
        self.service = self.new_service()

    def new_service(self):
        return capture.ChangeCapture(backend.db, self.factory, backend.encrypt_catalog_payload,
            backend.decrypt_catalog_payload, backend.record_audit_event, now=lambda: self.now)

    def tearDown(self):
        self.settings.stop()
        self.directory.cleanup()

    def payload(self, **changes):
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox", "entityType": "Item", **changes}

    def run_capture(self, **changes):
        return self.service.capture(self.admin, self.payload(**changes))

    def rows(self, table):
        self.assertIn(table, {"qbo_capture_cursors", "qbo_capture_versions", "qbo_capture_batches", "audit_events"})
        with backend.db() as connection:
            return [dict(row) for row in connection.execute("SELECT * FROM " + table)]

    def assert_code(self, code, action):
        with self.assertRaises(capture.AttemptError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def test_initial_full_census_then_overlapping_cdc_preserves_original_and_current_versions(self):
        result = self.run_capture()
        self.assertEqual([value["record"]["UnitPrice"] for value in result["versions"]], [125, 135])
        self.assertEqual(result["applicationState"], "not_applied")
        self.assertEqual(result["revision"], 1)
        self.assertEqual(self.calls[0], ("census", "Item"))
        self.assertEqual(capture.timestamp(self.calls[1][2]), self.now - capture.OVERLAP)
        self.assertEqual(self.rows("qbo_capture_batches")[0]["mode"], "baseline")
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["captured_through"], capture.stamp(self.now))

    def test_restart_deduplicates_and_incremental_capture_never_rewrites_prior_versions(self):
        first = self.run_capture()
        original_rows = self.rows("qbo_capture_versions")
        self.service = self.new_service()
        self.now += timedelta(minutes=3)
        second = self.run_capture()
        self.assertEqual(self.rows("qbo_capture_versions"), original_rows)
        self.assertEqual(second["throughSequence"], first["throughSequence"])
        self.assertEqual([value[0] for value in self.calls], ["census", "changes", "census", "changes"])
        self.assertEqual(self.rows("qbo_capture_batches")[1]["new_version_count"], 0)
        self.assertIsNone(first["baselineAt"])
        self.assertEqual(first["issueCode"], "baseline_changed")
        self.assertIsNotNone(second["baselineAt"])
        self.run_capture()
        self.assertEqual([value[0] for value in self.calls][-1], "changes")
        self.assertEqual(len(self.calls), 5)

    def test_deleted_and_late_versions_remain_history_not_financial_mutations(self):
        self.run_capture()
        self.now += timedelta(minutes=1)
        self.changes = [record(when=self.now, deleted=True)]
        result = self.run_capture()
        self.assertEqual([value["status"] for value in result["versions"]], ["present", "present", "deleted"])
        self.assertEqual(result["versions"][0]["record"]["UnitPrice"], 125)
        self.assertEqual(result["applicationState"], "not_applied")
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM qbo_webhook_events WHERE acknowledged_at IS NOT NULL").fetchone()[0], 0)

    def test_each_collection_has_independent_cursor_and_versions(self):
        self.run_capture()
        self.run_capture(entityType="Invoice")
        self.assertEqual(len(self.rows("qbo_capture_cursors")), 2)
        self.assertEqual(len(self.rows("qbo_capture_versions")), 4)
        for entity in ("Item", "Invoice"):
            self.assertEqual(len(self.service.read(self.admin, self.payload(entityType=entity))["versions"]), 2)

    def test_history_and_grant_metadata_are_encrypted_and_not_in_status(self):
        result = self.run_capture()
        rows = self.rows("qbo_capture_versions")
        self.assertNotIn("Private fixture", json.dumps(rows))
        for key in ("grant_fingerprint", "ciphertext", "actor_email", "payload_hash"):
            self.assertNotIn(key, json.dumps(result))
        self.assertIn("Private fixture", backend.decrypt_catalog_payload(rows[0]["payload_ciphertext"]))

    def insert_event(self, identifier, *, when=None, entity="item", environment="sandbox", company=None, legacy=False, acknowledged=False):
        with backend.db() as connection:
            connection.execute("""INSERT INTO qbo_webhook_events
                (event_id,realm_id,entity_type,entity_id,operation,occurred_at,received_at,company_id,environment,acknowledged_at)
                VALUES (?,'realm',?,'42','updated',?,?,?,?,?)""",
                (identifier, entity, capture.stamp(when or self.now), capture.stamp(self.now),
                 None if legacy else (company or self.company), None if legacy else environment,
                 "legacy-native-ack" if acknowledged else None))

    def test_backlog_and_late_old_notifications_rewind_by_receipt_order_even_after_legacy_ack(self):
        old = self.now - timedelta(days=4)
        self.insert_event("old", when=old, acknowledged=True)
        self.run_capture()
        self.assertEqual(capture.timestamp(self.calls[-1][2]), old - capture.OVERLAP)
        first_position = self.rows("qbo_capture_cursors")[0]["webhook_position"]
        self.now += timedelta(minutes=1)
        late = self.now - timedelta(days=7)
        self.insert_event("late", when=late)
        self.run_capture()
        self.assertEqual(capture.timestamp(self.calls[-1][2]), late - capture.OVERLAP)
        self.assertGreater(self.rows("qbo_capture_cursors")[0]["webhook_position"], first_position)
        self.run_capture()
        self.assertEqual(capture.timestamp(self.calls[-1][2]), self.now - capture.OVERLAP)

    def test_notification_during_capture_is_not_consumed_or_lost(self):
        self.before_changes = lambda: self.insert_event("during-read", when=self.now - timedelta(days=2))
        self.run_capture()
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)
        self.before_changes = lambda: None
        self.run_capture()
        self.assertEqual(capture.timestamp(self.calls[-1][2]), self.now - timedelta(days=2) - capture.OVERLAP)
        self.assertGreater(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)

    def test_foreign_notifications_do_not_rewind_and_legacy_scope_is_not_guessed(self):
        old = self.now - timedelta(days=50)
        self.insert_event("foreign-company", company=str(uuid.uuid4()), when=old)
        self.insert_event("foreign-environment", environment="production", when=old)
        self.insert_event("other-entity", entity="invoice", when=old)
        self.insert_event("legacy", legacy=True, when=old)
        result = self.run_capture()
        self.assertEqual(result["legacyEventsNeedingReview"], 1)
        self.assertEqual(capture.timestamp(self.calls[-1][2]), self.now - capture.OVERLAP)
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)

    def test_old_backlog_needs_recovery_not_silent_window_clipping(self):
        self.insert_event("too-old", when=self.now - timedelta(days=31))
        self.assert_code("history_gap", self.run_capture)
        self.assertFalse(self.calls)
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)

    def test_missing_record_keeps_original_event_pending_and_rewinds_again(self):
        old = self.now - timedelta(days=2)
        self.insert_event("missing-record", when=old)
        self.changes = []
        first = self.run_capture()
        self.assertEqual(first["issueCode"], "event_record_missing")
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)
        self.now += timedelta(minutes=1)
        self.run_capture()
        self.assertEqual(capture.timestamp(self.calls[-1][2]), old - capture.OVERLAP)
        self.changes = [record(when=self.now)]
        self.run_capture()
        self.assertGreater(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)

    def test_merge_requires_both_survivor_and_actual_deleted_identity_evidence(self):
        self.insert_event("merge", when=self.now)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_webhook_events SET operation='merged',deleted_entity_id='removed'")
        first = self.run_capture()
        self.assertEqual(first["issueCode"], "event_record_missing")
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)
        self.changes.append(record("removed", when=self.now, deleted=True))
        result = self.run_capture()
        self.assertGreater(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)
        self.assertEqual(result["applicationState"], "not_applied")
        with backend.db() as connection:
            self.assertIsNone(connection.execute("SELECT acknowledged_at FROM qbo_webhook_events").fetchone()[0])

    def test_deleted_notification_cannot_be_represented_by_an_ordinary_snapshot(self):
        self.insert_event("deletion", when=self.now)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_webhook_events SET operation='deleted'")
        self.run_capture()
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)
        self.changes = [record(when=self.now, deleted=True)]
        self.run_capture()
        self.assertGreater(self.rows("qbo_capture_cursors")[0]["webhook_position"], 0)

    def test_revocation_during_history_decryption_is_checked_against_fresh_state(self):
        self.run_capture()
        with backend.db() as connection:
            connection.execute("PRAGMA journal_mode=WAL")
        original = self.service.decrypt
        def revoke_while_decrypting(ciphertext):
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at='now'")
            return original(ciphertext)
        self.service.decrypt = revoke_while_decrypting
        self.assert_code("administrator_required", lambda: self.service.read(self.admin, self.payload()))

    def test_nonadmin_missing_expired_inactive_and_primary_email_shortcuts_are_denied(self):
        for role in ("Accounting", "Dispatcher", "Field Technician", "Standard"):
            self.assert_code("administrator_required", lambda: self.service.capture(self.sessions[role], self.payload()))
        self.assert_code("administrator_required", lambda: self.service.capture("missing", self.payload()))
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Standard' WHERE role='Admin'")
        with mock.patch.object(backend, "PRIMARY_ADMIN_EMAIL", "admin@example.invalid"):
            self.assert_code("administrator_required", self.run_capture)
        self.assertFalse(self.calls)
        self.assertFalse(self.rows("qbo_capture_versions"))

    def test_company_realm_and_environment_are_checked_before_reads_and_history(self):
        for change, code in (({"companyID": str(uuid.uuid4())}, "company_changed"), ({"realmID": "other"}, "provider_changed"),
                             ({"environment": "production"}, "provider_changed")):
            self.assert_code(code, lambda: self.run_capture(**change))
            self.assert_code(code, lambda: self.service.read(self.admin, self.payload(**change)))
        self.assertFalse(self.calls)

    def test_revoked_access_or_changed_grant_between_resources_cannot_commit(self):
        def revoke():
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at='now'")
        self.before_changes = revoke
        self.assert_code("administrator_required", self.run_capture)
        self.assertFalse(self.rows("qbo_capture_versions"))
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET revoked_at=NULL")
        def reconnect():
            with backend.db() as connection:
                connection.execute("UPDATE qbo_connections SET authorized_at='new-grant'")
        self.before_changes = reconnect
        self.assert_code("grant_changed", self.run_capture)
        self.assertFalse(self.rows("qbo_capture_versions"))

    def test_provider_failure_and_history_window_expiration_retain_original_cursor(self):
        self.run_capture()
        through = self.rows("qbo_capture_cursors")[0]["captured_through"]
        count = len(self.rows("qbo_capture_versions"))
        self.before_changes = mock.Mock(side_effect=capture.failure("provider_throttled", "fixture busy", 503))
        self.assert_code("provider_throttled", self.run_capture)
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["captured_through"], through)
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["issue_code"], "provider_throttled")
        self.now += timedelta(days=31)
        # Keep a current fixture session to isolate the CDC-window boundary.
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET expires_at=?", (capture.stamp(self.now + timedelta(days=1)),))
        self.assert_code("history_gap", self.run_capture)
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["captured_through"], through)
        self.assertEqual(len(self.rows("qbo_capture_versions")), count)

    def test_failed_encryption_or_commit_rolls_back_history_and_cursor_together(self):
        self.service.encrypt = mock.Mock(side_effect=RuntimeError("fixture storage"))
        with self.assertRaises(RuntimeError):
            self.run_capture()
        self.assertFalse(self.calls)
        self.service.encrypt = backend.encrypt_catalog_payload
        self.service.audit = mock.Mock(side_effect=sqlite3.OperationalError("fixture disk"))
        with self.assertRaises(sqlite3.OperationalError):
            self.run_capture()
        self.assertFalse(self.rows("qbo_capture_versions"))
        self.assertFalse(self.rows("qbo_capture_batches"))
        self.assertIsNone(self.rows("qbo_capture_cursors")[0]["captured_through"])

    def test_newer_capture_cannot_be_overwritten_by_older_suspended_request(self):
        once = [False]
        def complete_newer():
            if not once[0]:
                once[0] = True
                self.new_service().capture(self.admin, self.payload())
        self.before_changes = complete_newer
        self.assert_code("capture_superseded", self.run_capture)
        self.assertEqual(len(self.rows("qbo_capture_batches")), 1)
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["revision"], 1)

    def test_history_pages_pin_high_watermark_across_new_captures(self):
        self.census = [record(str(index), when=self.now - timedelta(days=1)) for index in range(105)]
        self.changes = []
        first = self.run_capture()
        self.assertEqual(len(first["versions"]), 50)
        maximum = first["throughSequence"]
        self.now += timedelta(minutes=1)
        self.changes = [record("new", when=self.now)]
        self.run_capture()
        second = self.service.read(self.admin, self.payload(), after=first["nextAfterSequence"], through=maximum)
        third = self.service.read(self.admin, self.payload(), after=second["nextAfterSequence"], through=maximum)
        all_ids = [v["entityID"] for page in (first, second, third) for v in page["versions"]]
        self.assertEqual(len(set(all_ids)), 105)
        self.assertNotIn("new", all_ids)
        self.assertIsNone(third["nextAfterSequence"])

    def test_swapped_ciphertext_or_modified_metadata_cannot_be_exposed(self):
        self.run_capture()
        with backend.db() as connection:
            connection.execute("UPDATE qbo_capture_versions SET entity_id='different' WHERE sequence=1")
        self.assert_code("history_unavailable", lambda: self.service.read(self.admin, self.payload()))

    def test_actual_provider_adapter_census_incremental_and_saturation_share_original_cursor(self):
        requests, remote_changes = [], []
        def send(request):
            requests.append(request)
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)
            if urllib.parse.urlsplit(request.full_url).path.endswith("/cdc"):
                return cdc(copy.deepcopy(remote_changes), when=self.now)
            sql = query["query"][0]
            if "COUNT(*)" in sql:
                return {"QueryResponse": {"totalCount": 1}, "time": capture.stamp(self.now)}
            return {"QueryResponse": {"Item": self.census, "startPosition": 1, "maxResults": 1}, "time": capture.stamp(self.now)}
        self.factory = lambda context, authorize: capture.ChangeCaptureQBOProvider(context, authorize, lambda *_: "fixture-not-live", send)
        self.service = self.new_service()
        first = self.run_capture()
        self.assertIsNotNone(first["baselineAt"])
        self.assertEqual(first["versions"][0]["record"]["UnitPrice"], 125)
        self.assertEqual(len(requests), 4)
        self.now += timedelta(minutes=1)
        remote_changes[:] = [record(when=self.now, UnitPrice=135)]
        second = self.run_capture()
        self.assertEqual([v["record"]["UnitPrice"] for v in second["versions"]], [125, 135])
        self.assertEqual(len(requests), 5)
        remote_changes[:] = [record(str(index), when=self.now) for index in range(1000)]
        self.assert_code("change_limit", self.run_capture)
        self.assertEqual(self.rows("qbo_capture_cursors")[0]["captured_through"], second["capturedThrough"])
        self.assertEqual(len(self.rows("qbo_capture_versions")), 2)
        self.assertEqual(len(self.rows("qbo_capture_batches")), 2)
        self.assertTrue(all(request.get_method() == "GET" and request.data is None for request in requests))

    def test_current_session_expiration_and_user_deactivation_deny_history(self):
        self.run_capture()
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET expires_at=?", (capture.stamp(self.now - timedelta(seconds=1)),))
        self.assert_code("administrator_required", lambda: self.service.read(self.admin, self.payload()))
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET expires_at=?", (capture.stamp(self.now + timedelta(days=1)),))
            connection.execute("UPDATE users SET is_active=0")
        self.assert_code("administrator_required", lambda: self.service.read(self.admin, self.payload()))

    def test_refresh_rotation_does_not_replace_grant_or_discard_history(self):
        def rotate():
            with backend.db() as connection:
                connection.execute("UPDATE qbo_connections SET refresh_token_ciphertext='new-fixture-cipher',updated_at='later'")
        self.before_changes = rotate
        self.assertEqual(self.run_capture()["revision"], 1)

    def test_backup_restores_encrypted_versions_batch_and_cursor_without_provider_access(self):
        from Backend import backup_backend
        self.run_capture()
        root = Path(self.directory.name)
        backend.STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
        backup_backend.create_backup(backend.DB_PATH, backend.STORAGE_ROOT, root / "backup")
        backup_backend.verify_backup(root / "backup")
        backup_backend.restore_drill(root / "backup", root / "restored")
        restored = root / "restored" / backup_backend.DATABASE_FILENAME
        self.calls.clear()
        with mock.patch.object(backend, "DB_PATH", restored):
            recovered = self.new_service().read(self.admin, self.payload())
            self.assertEqual(recovered["revision"], 1)
            self.assertEqual(len(recovered["versions"]), 2)
            self.assertEqual(len(self.rows("qbo_capture_batches")), 1)
        self.assertFalse(self.calls)

    def test_schema_initializer_never_commits_its_callers_transaction(self):
        connection = sqlite3.connect(":memory:")
        try:
            connection.execute("BEGIN")
            capture.initialize_schema(connection)
            self.assertTrue(connection.in_transaction)
            connection.rollback()
            self.assertIsNone(connection.execute("SELECT name FROM sqlite_master WHERE name='qbo_capture_versions'").fetchone())
        finally:
            connection.close()

    def test_http_requires_app_session_strict_fields_and_exact_scoped_pages(self):
        service = self.service
        with mock.patch.object(capture, "ChangeCapture", return_value=service):
            server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            url = f"http://127.0.0.1:{server.server_port}/api/qbo/change-capture"
            try:
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(url, timeout=5)
                self.assertEqual(caught.exception.code, 401)
                headers = {"Authorization": "Bearer " + self.tokens["Admin"], "Content-Type": "application/json"}
                request = urllib.request.Request(url, data=json.dumps(self.payload()).encode(), headers=headers)
                with urllib.request.urlopen(request, timeout=5) as response:
                    self.assertEqual(json.load(response)["applicationState"], "not_applied")
                request = urllib.request.Request(url + "?" + urllib.parse.urlencode(self.payload()), headers=headers)
                with urllib.request.urlopen(request, timeout=5) as response:
                    self.assertEqual(len(json.load(response)["versions"]), 2)
                for body in (b'{"companyID":"one","companyID":"two"}', b'{}', json.dumps({**self.payload(), "url": "https://example.invalid"}).encode()):
                    with self.assertRaises(urllib.error.HTTPError) as caught:
                        urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers), timeout=5)
                    self.assertEqual(caught.exception.code, 400)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
