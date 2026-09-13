from __future__ import annotations

import base64
import copy
import hashlib
import io
import json
from email import policy
from email.parser import BytesParser
import sqlite3
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from unittest import mock

from Backend import gunnaire_backend as backend, qbo_document_uploads as uploads, qbo_document_provider as adapter
from Backend.test_billing_publications import BillingFixture


class DocumentUploadTests(BillingFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.sent, self.matches, self.reads = [], [], []
        self.before_send = lambda: None
        self.after_send = lambda value: value
        fixture = self
        class Provider:
            def __init__(self, context, authorize):
                self.authorize = authorize

            def read_target(self, kind, identifier):
                fixture.reads.append((kind, identifier))
                fixture.before_read(); self.authorize()
                return {"Id": identifier}

            def upload(self, metadata, data, request_id, claim):
                fixture.before_send(); claim(); self.authorize()
                fixture.sent.append((copy.deepcopy(metadata), data, request_id))
                value = {**copy.deepcopy(metadata), "Id": "A1", "Size": len(data)}
                fixture.matches = [value]
                result = fixture.after_send(copy.deepcopy(value))
                self.authorize()
                return result

            def find(self, note):
                fixture.before_read(); self.authorize()
                return copy.deepcopy(fixture.matches)
        self.provider_type = Provider
        self.service = uploads.DocumentUploads(backend.db, Provider, backend.encrypt_catalog_payload,
                                               backend.decrypt_catalog_payload, backend.record_audit_event)

    def query(self, **changes):
        return {"companyID": self.company, "realmID": "realm", "environment": "sandbox", **changes}

    def upload_request(self, **changes):
        return {**self.query(), "operationID": str(uuid.uuid4()),
                "connectionRevision": self.payload()["connectionRevision"],
                "file": {"filename": "Service report.txt", "contentType": "text/plain",
                         "data": base64.b64encode(b"Retain the original service findings.").decode()},
                "targets": [{"type": "Invoice", "id": "D1"}], **changes}

    @contextmanager
    def http(self, send=None):
        def factory(context, authorize, bearer):
            if send is None:
                return self.provider_type(context, authorize)
            return adapter.DocumentQBOProvider(context, authorize, lambda *_: "fixture-only-token", send=send)
        patch = mock.patch.object(backend, "DocumentQBOProvider", side_effect=factory)
        patch.start()
        server = backend.ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        def request(path, payload=None, role="Admin", raw=None):
            req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}" + path,
                data=raw if raw is not None else json.dumps(payload).encode() if payload is not None else None,
                headers={"Authorization": "Bearer " + self.tokens[role], "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=5) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)
        try:
            yield request
        finally:
            server.shutdown(); server.server_close(); thread.join(timeout=5)
            patch.stop()

    def test_http_reserves_original_file_before_any_provider_post(self):
        with self.http() as request:
            status, result = request("/api/qbo-document-uploads", self.upload_request())
        self.assertEqual(status, 200)
        self.assertEqual(result["state"], "reserved")
        self.assertIsNone(result["providerID"])
        self.assertNotIn("data", json.dumps(result))

    def reserve(self, payload=None):
        return self.service.reserve(self.admin, payload or self.upload_request())

    def send(self, record):
        return self.service.send(self.admin, record["id"], record["revision"])

    def row(self, identifier):
        with backend.db() as connection:
            return dict(connection.execute("SELECT * FROM qbo_document_uploads WHERE id=?", (identifier,)).fetchone())

    def test_reserved_bytes_metadata_and_state_are_encrypted_and_explicit_file_read_is_exact(self):
        payload = self.upload_request()
        result = self.reserve(payload)
        row = self.row(result["id"])
        self.assertNotIn("Service report.txt", str(row))
        self.assertNotIn(payload["file"]["data"], str(row))
        self.assertFalse(self.sent or self.reads)
        recovered = self.service.read(self.admin, result["id"], include_file=True)
        self.assertEqual(recovered["data"], payload["file"]["data"])
        self.assertEqual(recovered["file"]["sha256"], hashlib.sha256(base64.b64decode(payload["file"]["data"])).hexdigest())
        self.assertEqual(self.service.lookup(self.admin, self.query(operationID=payload["operationID"]))["uploads"], [result])
        self.assertNotIn("data", self.service.lookup(self.admin, self.query())["uploads"][0])

    def test_sending_verifies_original_targets_and_confirms_only_one_file_without_customer_send(self):
        record = self.reserve()
        result = self.send(record)
        self.assertEqual((result["state"], result["providerID"]), ("confirmed", "A1"))
        self.assertEqual(self.reads, [("Invoice", "D1")])
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0][2], "ga-file-" + record["id"])
        self.assertIs(self.sent[0][0]["AttachableRef"][0]["IncludeOnSend"], False)
        self.assertEqual(self.send(record), result)
        self.assertEqual(self.service.recover(self.admin, record["id"]), result)
        self.assertEqual(len(self.sent), 1)

    def test_same_operation_and_new_operation_duplicate_converge_and_both_lookups_recover(self):
        payload = self.upload_request(); first = self.reserve(payload)
        self.assertEqual(self.reserve(payload), first)
        other = {**payload, "operationID": str(uuid.uuid4())}
        self.assertEqual(self.reserve(other), first)
        self.assertEqual(self.service.lookup(self.admin, self.query(operationID=other["operationID"]))["uploads"], [first])
        self.send(first)
        self.assertEqual(self.reserve(other)["providerID"], "A1")
        self.assertEqual(len(self.sent), 1)

    def test_changed_original_file_type_content_or_targets_cannot_reuse_operation(self):
        payload = self.upload_request(); self.reserve(payload)
        for change in ({"targets": []}, {"file": {**payload["file"], "filename": "Other.txt"}},
                       {"file": {**payload["file"], "data": base64.b64encode(b"changed").decode()}},
                       {"targets": [{"type": "Estimate", "id": "D1"}]}):
            self.expect("upload_changed", lambda: self.reserve({**payload, **change}))
        self.assertFalse(self.sent)

    def test_changed_grant_never_relabels_original_or_creates_duplicate_with_new_operation(self):
        payload = self.upload_request(); record = self.reserve(payload)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='replacement-grant'")
        self.expect("grant_changed", lambda: self.send(record))
        self.assertTrue(self.service.read(self.admin, record["id"])["connectionChanged"])
        self.assertEqual(self.reserve(payload)["id"], record["id"])
        new = self.upload_request()
        duplicate = self.reserve(new)
        self.assertEqual(duplicate["id"], record["id"])
        self.assertTrue(duplicate["connectionChanged"])
        self.assertEqual(self.service.recover(self.admin, record["id"])["state"], "reserved")
        self.assertFalse(self.sent)

    def test_lost_upload_reply_can_only_read_original_and_never_send_again(self):
        record = self.reserve()
        def lose(_):
            raise TimeoutError("sensitive-provider-response")
        self.after_send = lose
        with self.assertRaises(TimeoutError):
            self.send(record)
        self.assertEqual(self.service.read(self.admin, record["id"])["state"], "uncertain")
        self.expect("upload_pending", lambda: self.send(record))
        result = self.service.recover(self.admin, record["id"])
        self.assertEqual((result["state"], result["providerID"]), ("confirmed", "A1"))
        self.assertEqual(len(self.sent), 1)

    def test_empty_recovery_is_not_permission_to_resend_or_cancel(self):
        record = self.reserve()
        self.service.claim(self.admin, record["id"], record["revision"])
        self.assertEqual(self.service.recover(self.admin, record["id"])["state"], "sending")
        self.expect("upload_pending", lambda: self.send(record))
        self.expect("upload_pending", lambda: self.service.cancel(self.admin, record["id"], record["revision"]))
        self.assertFalse(self.sent)

    def test_duplicates_wrong_file_wrong_size_or_wrong_links_are_not_confirmation(self):
        for alteration in (lambda value: {**value, "Size": True}, lambda value: {**value, "Size": 10},
                           lambda value: {**value, "FileName": "Other.txt"}, lambda value: {**value, "Note": "Other"},
                           lambda value: {**value, "ContentType": "text/csv"}, lambda value: {**value, "AttachableRef": []},
                           lambda value: {**value, "AttachableRef": [{**value["AttachableRef"][0], "Inactive": True}]},
                           lambda value: {**value, "AttachableRef": [{"EntityRef": {"type": "Invoice", "value": "D1"}, "IncludeOnSend": True}]}):
            record = self.reserve(self.upload_request(file={"filename": str(uuid.uuid4()) + ".txt", "contentType": "text/plain", "data": "YQ=="}))
            self.after_send = alteration
            self.expect("upload_unconfirmed", lambda: self.send(record))
            self.assertEqual(self.service.read(self.admin, record["id"])["state"], "uncertain")
            self.matches = [alteration(self.matches[0])]
            self.expect("upload_unconfirmed", lambda: self.service.recover(self.admin, record["id"]))
        self.matches = [self.matches[0], self.matches[0]]
        self.expect("upload_unconfirmed", lambda: self.service.recover(self.admin, record["id"]))

    def test_cancel_retains_bytes_and_tombstone_but_never_calls_provider(self):
        payload = self.upload_request(); record = self.reserve(payload)
        result = self.service.cancel(self.admin, record["id"], record["revision"])
        self.assertEqual(result["state"], "cancelled")
        self.assertEqual(self.service.cancel(self.admin, record["id"], record["revision"]), result)
        self.assertEqual(self.service.read(self.admin, record["id"], include_file=True)["data"], payload["file"]["data"])
        self.expect("upload_cancelled", lambda: self.send(record))
        self.assertEqual(self.reserve(payload), result)
        self.assertNotEqual(self.reserve()["id"], record["id"])
        self.assertFalse(self.sent or self.reads)

    def test_every_entry_point_requires_current_admin_and_original_company(self):
        record = self.reserve()
        for role in ("Accounting", "Dispatcher", "Field Technician", "Standard"):
            session = self.sessions[role]
            for action in (lambda: self.service.read(session, record["id"], include_file=True),
                           lambda: self.service.lookup(session, self.query()), lambda: self.service.reserve(session, self.upload_request()),
                           lambda: self.service.send(session, record["id"], record["revision"]),
                           lambda: self.service.recover(session, record["id"]),
                           lambda: self.service.cancel(session, record["id"], record["revision"])):
                self.expect("administrator_required", action)
        with backend.db() as connection:
            connection.execute("UPDATE company_identity SET company_id=?", (str(uuid.uuid4()),))
        self.expect("company_changed", lambda: self.service.read(self.admin, record["id"], include_file=True))
        self.expect("company_changed", lambda: self.send(record))
        self.assertFalse(self.sent)

    def test_revocation_or_reconnection_during_target_read_prevents_dispatch(self):
        record = self.reserve()
        def revoke():
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE id=?", (backend.utc_now(), self.admin))
        self.before_read = revoke
        self.expect("access_denied", lambda: self.send(record))
        self.assertEqual(self.row(record["id"])["state"], "reserved")
        self.assertFalse(self.sent)

    def test_reconnection_after_post_retains_uncertainty_without_late_confirmation(self):
        record = self.reserve()
        def reconnect(value):
            with backend.db() as connection:
                connection.execute("UPDATE qbo_connections SET authorized_at='new-grant'")
            return value
        self.after_send = reconnect
        self.expect("grant_changed", lambda: self.send(record))
        result = self.service.read(self.admin, record["id"])
        self.assertEqual(result["state"], "uncertain")
        self.assertIsNone(result["providerID"])
        self.assertEqual(len(self.sent), 1)

    def test_explicit_reconnected_review_can_find_original_but_never_adopt_grant_for_resend(self):
        record = self.reserve(); original_grant = self.row(record["id"])["grant_fingerprint"]
        def lose(_):
            raise TimeoutError()
        self.after_send = lose
        with self.assertRaises(TimeoutError):
            self.send(record)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_connections SET authorized_at='reconnected'")
        self.expect("grant_changed", lambda: self.send(record))
        result = self.service.recover(self.admin, record["id"])
        self.assertEqual((result["state"], result["providerID"]), ("confirmed", "A1"))
        self.assertTrue(result["connectionChanged"])
        self.assertEqual(self.row(record["id"])["grant_fingerprint"], original_grant)
        self.assertEqual(len(self.sent), 1)

    def test_second_reconnection_during_recovery_cannot_confirm_stale_read_evidence(self):
        record = self.reserve(); self.service.claim(self.admin, record["id"], record["revision"])
        def change():
            with backend.db() as connection:
                connection.execute("UPDATE qbo_connections SET authorized_at='changed-during-review'")
        self.before_read = change
        self.expect("grant_changed", lambda: self.service.recover(self.admin, record["id"]))
        self.assertEqual(self.row(record["id"])["state"], "sending")
        self.assertFalse(self.sent)

    def test_corrupt_file_payload_state_or_operation_alias_stops_before_send(self):
        for column in ("file_ciphertext", "payload_ciphertext", "state_ciphertext"):
            record = self.reserve(self.upload_request(file={"filename": str(uuid.uuid4()) + ".txt", "contentType": "text/plain", "data": "YQ=="}))
            with backend.db() as connection:
                connection.execute("UPDATE qbo_document_uploads SET " + column + "='corrupted' WHERE id=?", (record["id"],))
            self.expect("storage_unavailable", lambda: self.send(record))
        payload = self.upload_request(); record = self.reserve(payload)
        with backend.db() as connection:
            connection.execute("UPDATE qbo_document_upload_operations SET upload_id=? WHERE operation_id=?", (str(uuid.uuid4()), payload["operationID"]))
        self.expect("storage_unavailable", lambda: self.service.lookup(self.admin, self.query(operationID=payload["operationID"])))
        self.assertFalse(self.sent)

    def test_plain_state_rewind_cannot_make_an_unknown_upload_retryable(self):
        record = self.reserve(); self.service.claim(self.admin, record["id"], record["revision"])
        with backend.db() as connection:
            connection.execute("UPDATE qbo_document_uploads SET state='reserved' WHERE id=?", (record["id"],))
        self.expect("storage_unavailable", lambda: self.send(record))
        self.assertFalse(self.sent)

    def test_audit_or_encryption_failure_rolls_back_reserve_and_claim(self):
        payload = self.upload_request()
        encrypt = self.service.encrypt
        self.service.encrypt = mock.Mock(side_effect=RuntimeError("encryption unavailable"))
        with self.assertRaises(RuntimeError):
            self.reserve(payload)
        self.service.encrypt = encrypt
        self.assertEqual(self.service.lookup(self.admin, self.query())["uploads"], [])
        original = self.service.audit
        self.service.audit = mock.Mock(side_effect=RuntimeError("audit unavailable"))
        with self.assertRaises(RuntimeError):
            self.reserve(payload)
        self.service.audit = original
        self.assertEqual(self.service.lookup(self.admin, self.query())["uploads"], [])
        record = self.reserve(payload)
        self.service.audit = mock.Mock(side_effect=RuntimeError("audit unavailable"))
        with self.assertRaises(RuntimeError):
            self.send(record)
        self.assertEqual(self.row(record["id"])["state"], "reserved")
        self.assertFalse(self.sent)

    def test_concurrent_reservations_and_dispatches_only_upload_one_original(self):
        payload = self.upload_request()
        with ThreadPoolExecutor(max_workers=2) as pool:
            records = list(pool.map(lambda _: self.reserve(payload), range(2)))
        self.assertEqual(records[0], records[1])
        barrier = threading.Barrier(2)
        self.before_send = lambda: barrier.wait(timeout=5)
        def dispatch(_):
            try:
                return self.send(records[0])
            except uploads.AttemptError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(dispatch, range(2)))
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(sum(isinstance(value, dict) and value["state"] == "confirmed" for value in results), 1)
        self.assertEqual(self.service.read(self.admin, records[0]["id"])["state"], "confirmed")

    def test_backup_restore_recovers_the_original_pending_file_and_only_one_post(self):
        payload = self.upload_request(); record = self.reserve(payload)
        restored = backend.Path(self.directory.name) / "restored.sqlite3"
        snapshot = sqlite3.connect(restored)
        with backend.db() as connection:
            connection.backup(snapshot)
        snapshot.close()
        with mock.patch.object(backend, "DB_PATH", restored):
            backend.initialize_database()
            self.assertEqual(self.service.read(self.admin, record["id"], include_file=True)["data"], payload["file"]["data"])
            self.assertEqual(self.send(record)["providerID"], "A1")
            self.assertEqual(self.send(record)["providerID"], "A1")
        self.assertEqual(len(self.sent), 1)

    def test_list_is_bounded_without_loading_or_returning_file_bytes(self):
        for _ in range(52):
            self.reserve(self.upload_request(file={"filename": str(uuid.uuid4()) + ".txt", "contentType": "text/plain", "data": "YQ=="}))
        with mock.patch.object(self.service, "bytes", side_effect=AssertionError("list must not decrypt files")):
            first = self.service.lookup(self.admin, self.query())
            second = self.service.lookup(self.admin, self.query(after=first["nextCursor"]))
        self.assertEqual((len(first["uploads"]), len(second["uploads"])), (50, 2))
        self.assertEqual(len({item["id"] for item in first["uploads"] + second["uploads"]}), 52)
        self.assertIsNone(second["nextCursor"])

    def test_strict_file_target_and_identity_validation_never_reserves_a_partial_record(self):
        payload = self.upload_request()
        invalid = [({"file": {**payload["file"], "filename": name}}, "invalid_file") for name in ("../private.txt", "secret\n.txt", 'bad".txt', "\ud800.txt", "file.exe")]
        invalid += [({"file": {**payload["file"], "data": data}}, "invalid_file") for data in ("", "*", "YQ", "YQ===", "YQ==\n")]
        invalid += [({"targets": [{"type": "Invoice", "id": "D1"}] * 2}, "invalid_target"), ({"targets": [{"type": {}, "id": "D1"}]}, "invalid_target"),
                    ({"role": "Admin"}, "invalid_request"), ({"url": "https://outside.invalid"}, "invalid_request"), ({"connectionRevision": "old"}, "invalid_request")]
        for changes, code in invalid:
            self.expect(code, lambda: self.reserve({**payload, **changes}))
        self.assertEqual(self.service.lookup(self.admin, self.query())["uploads"], [])

    def test_http_real_adapter_preserves_binary_unicode_filename_and_recovers_lost_reply(self):
        original = bytes(range(256)) * 4
        payload = self.upload_request(file={"filename": "pièce-été.pdf", "contentType": "application/pdf", "data": base64.b64encode(original).decode()})
        requests, remote = [], None
        def send(request):
            nonlocal remote
            requests.append(request)
            parsed = urllib.parse.urlsplit(request.full_url)
            self.assertEqual(parsed.hostname, "sandbox-quickbooks.api.intuit.com")
            self.assertEqual(request.get_header("Authorization"), "Bearer fixture-only-token")
            if parsed.path.endswith("/invoice/D1"):
                return {"Invoice": {"Id": "D1"}}
            if request.get_method() == "POST":
                self.assertTrue(parsed.path.endswith("/upload"))
                message = BytesParser(policy=policy.default).parsebytes(
                    ("Content-Type: " + request.get_header("Content-type") + "\r\nMIME-Version: 1.0\r\n\r\n").encode() + request.data)
                parts = list(message.iter_parts())
                self.assertEqual(len(parts), 2)
                metadata = json.loads(parts[0].get_payload(decode=True))
                self.assertEqual(parts[1].get_filename(), payload["file"]["filename"])
                self.assertEqual(parts[1].get_payload(decode=True), original)
                self.assertFalse(metadata["AttachableRef"][0]["IncludeOnSend"])
                remote = {**metadata, "Id": "A1", "Size": len(original)}
                raise TimeoutError("private provider body must not appear")
            query = urllib.parse.parse_qs(parsed.query)["query"][0]
            self.assertIn("WHERE Note = '" + remote["Note"] + "'", query)
            return {"QueryResponse": {"Attachable": [remote], "startPosition": 1, "maxResults": 1}}
        with self.http(send=send) as request:
            status, record = request("/api/qbo-document-uploads", payload)
            self.assertEqual(status, 200)
            self.assertFalse(requests)
            path = "/api/qbo-document-uploads/" + record["id"]
            status, error = request(path + "/send", {"revision": record["revision"]})
            self.assertEqual((status, error["code"]), (502, "provider_unavailable"))
            self.assertNotIn("private provider", json.dumps(error))
            self.assertEqual(request(path)[1]["state"], "uncertain")
            self.assertEqual(request(path + "/send", {"revision": record["revision"]})[1]["code"], "upload_pending")
            status, recovered = request(path + "/recover", {})
            self.assertEqual((status, recovered["providerID"]), (200, "A1"))
            self.assertEqual(request(path + "/file")[1]["data"], payload["file"]["data"])
            self.assertEqual(request("/api/qbo-document-uploads?" + urllib.parse.urlencode(self.query(operationID=payload["operationID"])))[1]["uploads"][0]["id"], record["id"])
        self.assertEqual(sum(req.get_method() == "POST" for req in requests), 1)

    def test_http_unknown_duplicate_fields_nonfinite_payloads_and_roles_are_rejected(self):
        with self.http() as request:
            for raw in (b'{"targets":[],"targets":[]}', b'{"file":NaN}', b'[]', b'{"nested":' + b'[' * 1100 + b'0' + b']' * 1100 + b'}'):
                self.assertEqual(request("/api/qbo-document-uploads", raw=raw)[0], 400)
            self.assertEqual(request("/api/qbo-document-uploads", self.upload_request(), role="Standard")[0], 403)
            record = self.reserve(); path = "/api/qbo-document-uploads/" + record["id"]
            for suffix, value in (("/send", {"revision": record["revision"], "force": True}), ("/recover", {"retry": True}),
                                  ("/cancel", {}), ("/reset", {}), ("/send?force=1", {"revision": record["revision"]})):
                self.assertEqual(request(path + suffix, value)[0], 400)
            self.assertEqual(request(path + "/file", role="Field Technician")[0], 403)
            self.assertEqual(request("/api/qbo-document-uploads?" + urllib.parse.urlencode(self.query()) + "&realmID=other")[0], 400)
        self.assertFalse(self.sent)

    def test_restore_after_provider_commit_retains_unknown_state_and_finds_the_same_file(self):
        record = self.reserve()
        def lose(_):
            raise TimeoutError()
        self.after_send = lose
        with self.assertRaises(TimeoutError):
            self.send(record)
        restored = backend.Path(self.directory.name) / "after-post.sqlite3"
        snapshot = sqlite3.connect(restored)
        with backend.db() as connection:
            connection.backup(snapshot)
        snapshot.close()
        with mock.patch.object(backend, "DB_PATH", restored):
            backend.initialize_database()
            self.expect("upload_pending", lambda: self.send(record))
            self.assertEqual(self.service.recover(self.admin, record["id"])["providerID"], "A1")
        self.assertEqual(len(self.sent), 1)

    def test_confirmation_storage_failure_still_cannot_resend_after_audit_recovers(self):
        record = self.reserve(); audit = self.service.audit
        def interrupt(value):
            self.service.audit = mock.Mock(side_effect=RuntimeError("storage unavailable"))
            return value
        self.after_send = interrupt
        with self.assertRaises(RuntimeError):
            self.send(record)
        self.assertEqual(self.row(record["id"])["state"], "sending")
        self.service.audit = audit
        self.expect("upload_pending", lambda: self.send(record))
        self.assertEqual(self.service.recover(self.admin, record["id"])["providerID"], "A1")
        self.assertEqual(len(self.sent), 1)

    def test_other_business_admin_can_recover_but_does_not_change_original_authorship(self):
        record = self.reserve()
        with backend.db() as connection:
            connection.execute("UPDATE users SET role='Admin' WHERE role='Accounting'")
        result = self.service.send(self.sessions["Accounting"], record["id"], record["revision"])
        self.assertEqual(result["providerID"], "A1")
        self.assertEqual(self.row(record["id"])["actor_email"], self.email("Admin"))

    def test_historical_file_is_retained_without_a_connection_but_cannot_be_sent(self):
        record = self.reserve()
        with backend.db() as connection:
            connection.execute("DELETE FROM qbo_connections")
        result = self.service.read(self.admin, record["id"], include_file=True)
        self.assertTrue(result["connectionChanged"])
        self.assertTrue(result["data"])
        self.assertIsNone(self.service.lookup(self.admin, self.query())["connectionRevision"])
        self.expect("provider_changed", lambda: self.send(record))
        self.assertEqual(self.service.cancel(self.admin, record["id"], record["revision"])["state"], "cancelled")

    def test_transport_logs_do_not_expose_recovery_queries_or_file_identifiers(self):
        handler = object.__new__(backend.GunnAireBackendHandler)
        handler.address_string = lambda: "fixture"
        with mock.patch("sys.stdout", new_callable=io.StringIO) as output:
            handler.log_message('"GET %s HTTP/1.1" 200 -', "/api/qbo-document-uploads/private-file-id/file?companyID=private-business")
        self.assertNotIn("private-file", output.getvalue())
        self.assertNotIn("private-business", output.getvalue())
        self.assertIn("qbo-document-uploads/[redacted]", output.getvalue())

    def test_list_declares_exact_protocol_and_file_limit_without_a_provider_call(self):
        result = self.service.lookup(self.admin, self.query())
        self.assertEqual((result["protocolVersion"], result["maxFileBytes"]), (1, uploads.MAX_FILE_BYTES))
        self.assertFalse(self.sent or self.reads)

    def test_old_owner_lookup_alias_tampering_cannot_select_a_different_valid_file(self):
        payload = self.upload_request(); first = self.reserve(payload)
        second = self.reserve(self.upload_request(targets=[]))
        with backend.db() as connection:
            connection.execute("UPDATE qbo_document_upload_operations SET upload_id=? WHERE operation_id=?", (second["id"], payload["operationID"]))
        self.expect("storage_unavailable", lambda: self.reserve(payload))
        self.expect("storage_unavailable", lambda: self.service.lookup(self.admin, self.query(operationID=payload["operationID"])))
        self.assertEqual(self.service.read(self.admin, first["id"])["state"], "reserved")

    def job_payload(self):
        job = str(uuid.uuid4())
        # Establish the same server-owned mapping used by the real billing
        # publisher, rather than trusting a device's transaction ID assertion.
        self.publish(self.payload(serviceCallID=job))
        return self.upload_request(jobDocument={
            "attachmentID": str(uuid.uuid4()), "serviceCallID": job,
            "localCustomerID": self.customer_id, "customerQuickBooksID": "C1",
            "kind": "service_report", "stage": "supporting",
            "documents": [{"type": "Invoice", "localID": self.local_id, "id": "D1"}]})

    def test_job_document_context_is_encrypted_retained_and_returned_for_exact_handoff(self):
        payload = self.job_payload(); record = self.reserve(payload)
        self.assertEqual(record["jobDocument"], payload["jobDocument"])
        self.assertNotIn(payload["jobDocument"]["attachmentID"], str(self.row(record["id"])))
        self.assertEqual(self.service.read(self.admin, record["id"], include_file=True)["jobDocument"], payload["jobDocument"])
        self.assertEqual(self.service.lookup(self.admin, self.query())["uploads"][0]["jobDocument"], payload["jobDocument"])
        self.assertFalse(self.sent or self.reads)

    def test_device_job_assertions_cannot_override_shared_customer_document_or_job_links(self):
        payload = self.job_payload()
        for key, value in (("serviceCallID", str(uuid.uuid4())), ("localCustomerID", str(uuid.uuid4())),
                           ("customerQuickBooksID", "C2"),
                           ("documents", [{"type": "Invoice", "localID": str(uuid.uuid4()), "id": "D1"}])):
            with self.subTest(key=key):
                self.expect("job_document_review", lambda: self.reserve({**payload, "jobDocument": {**payload["jobDocument"], key: value}}))
        self.assertFalse(self.sent or self.reads)
        self.assertEqual(self.service.lookup(self.admin, self.query())["uploads"], [])

    def test_job_source_shape_type_and_internal_only_files_are_rejected(self):
        payload = self.job_payload(); source = payload["jobDocument"]
        for changes in ({"kind": "expense_receipt"}, {"kind": "fleet_service"}, {"kind": "estimate_support"},
                        {"stage": "complete"}, {"role": "Admin"}, {"documents": []},
                        {"documents": [{"type": "Estimate", "localID": self.local_id, "id": "D1"}]}):
            self.expect("invalid_job_document", lambda: self.reserve({**payload, "jobDocument": {**source, **changes}}))
        self.expect("invalid_job_document", lambda: self.reserve({**payload, "jobDocument": None}))
        self.assertEqual(self.service.lookup(self.admin, self.query())["uploads"], [])

    def test_original_operation_or_duplicate_content_cannot_adopt_another_job_context(self):
        payload = self.job_payload(); record = self.reserve(payload)
        changed = {**payload, "jobDocument": {**payload["jobDocument"], "attachmentID": str(uuid.uuid4())}}
        self.expect("upload_changed", lambda: self.reserve(changed))
        self.expect("document_context_changed", lambda: self.reserve({**changed, "operationID": str(uuid.uuid4())}))
        standalone = {key: value for key, value in payload.items() if key != "jobDocument"}
        self.expect("document_context_changed", lambda: self.reserve({**standalone, "operationID": str(uuid.uuid4())}))
        self.assertEqual(self.reserve({**payload, "operationID": str(uuid.uuid4())})["id"], record["id"])
        self.assertFalse(self.sent)

    def test_missing_or_changed_shared_job_mapping_blocks_send_but_keeps_original_file_readable(self):
        payload = self.job_payload(); record = self.reserve(payload)
        with backend.db() as connection:
            connection.execute("DELETE FROM billing_job_documents")
        self.expect("job_document_review", lambda: self.send(record))
        restored = self.service.read(self.admin, record["id"], include_file=True)
        self.assertEqual(restored["jobDocument"], payload["jobDocument"])
        self.assertEqual(restored["state"], "reserved")
        self.assertFalse(self.sent or self.reads)

    def test_remote_customer_mismatch_cannot_attach_an_original_job_file(self):
        payload = self.job_payload(); record = self.reserve(payload)
        # The simple provider fixture intentionally lacks a CustomerRef.
        self.expect("job_document_review", lambda: self.send(record))
        self.assertFalse(self.sent)
        self.assertEqual(self.row(record["id"])["state"], "reserved")

    def test_job_link_change_during_provider_read_stops_dispatch(self):
        payload = self.job_payload(); record = self.reserve(payload)
        def change():
            with backend.db() as connection:
                connection.execute("UPDATE billing_job_documents SET service_call_id=?", (str(uuid.uuid4()),))
        self.before_read = change
        self.expect("job_document_review", lambda: self.send(record))
        self.assertFalse(self.sent)

    def test_exact_job_file_provider_success_retains_job_context_without_changing_job_progress(self):
        payload = self.job_payload()
        def send(request):
            if request.get_method() == "GET":
                return {"Invoice": {"Id": "D1", "CustomerRef": {"value": "C1"}}}
            parsed = BytesParser(policy=policy.default).parsebytes(
                ("Content-Type: " + request.get_header("Content-type") + "\r\n\r\n").encode() + request.data)
            parts = list(parsed.iter_parts())
            metadata = json.loads(parts[0].get_payload(decode=True))
            self.assertNotIn("jobDocument", metadata)
            return {"AttachableResponse": [{"Attachable": {**metadata, "Id": "A1", "Size": len(parts[1].get_payload(decode=True))}}]}
        with self.http(send=send) as request:
            status, record = request("/api/qbo-document-uploads", payload)
            self.assertEqual(status, 200)
            status, result = request("/api/qbo-document-uploads/" + record["id"] + "/send", {"revision": record["revision"]})
            self.assertEqual((status, result["state"], result["providerID"]), (200, "confirmed", "A1"))
            self.assertEqual(result["jobDocument"], payload["jobDocument"])

    def test_late_job_mapping_change_cannot_confirm_after_the_upload_left_the_server(self):
        payload = self.job_payload(); record = self.reserve(payload)
        def read_target(provider, kind, identifier):
            provider.authorize()
            return {"Id": identifier, "CustomerRef": {"value": "C1"}}
        def change(value):
            with backend.db() as connection:
                connection.execute("DELETE FROM billing_job_documents")
            return value
        self.after_send = change
        with mock.patch.object(self.provider_type, "read_target", read_target):
            self.expect("job_document_review", lambda: self.send(record))
            self.expect("job_document_review", lambda: self.service.recover(self.admin, record["id"]))
        result = self.service.read(self.admin, record["id"], include_file=True)
        self.assertEqual(result["state"], "uncertain")
        self.assertEqual(result["jobDocument"], payload["jobDocument"])
        self.assertEqual(len(self.sent), 1)

    def test_job_recovery_rechecks_current_provider_customer_without_a_replacement_post(self):
        payload = self.job_payload(); record = self.reserve(payload)
        customer = "C1"
        def read_target(provider, kind, identifier):
            provider.authorize()
            return {"Id": identifier, "CustomerRef": {"value": customer}}
        def lose(_):
            raise TimeoutError()
        self.after_send = lose
        with mock.patch.object(self.provider_type, "read_target", read_target):
            with self.assertRaises(TimeoutError):
                self.send(record)
            customer = "C2"
            self.expect("job_document_review", lambda: self.service.recover(self.admin, record["id"]))
            self.assertEqual(self.row(record["id"])["state"], "uncertain")
            customer = "C1"
            self.assertEqual(self.service.recover(self.admin, record["id"])["providerID"], "A1")
        self.assertEqual(len(self.sent), 1)


class DocumentProviderTests(unittest.TestCase):
    def setUp(self):
        self.context = {"realm_id": "realm", "environment": "sandbox"}
        self.sent = []
        self.authorize = mock.Mock()
        self.load = mock.Mock(return_value="fixture-token")
        self.provider = adapter.DocumentQBOProvider(self.context, self.authorize, self.load, send=lambda request: self.sent.append(request) or {})

    def test_adapter_rejects_arbitrary_resources_before_loading_a_token(self):
        for resource, query in (("invoice", None), ("https://outside.invalid", None), ("invoice/../secret", None),
                                ("query", {"query": "SELECT * FROM Customer"}), ("query", {"query": "SELECT * FROM Attachable"})):
            with self.assertRaises(uploads.AttemptError):
                self.provider.request(resource, query)
        self.load.assert_not_called(); self.assertFalse(self.sent)

    def test_adapter_revalidates_authority_after_token_refresh_before_any_io(self):
        self.load.side_effect = lambda *_: self.authorize.configure_mock(side_effect=uploads.failure("grant_changed", "fixture")) or "fixture-token"
        with self.assertRaises(uploads.AttemptError):
            self.provider.read_target("Invoice", "D1")
        self.assertFalse(self.sent)

    def test_lookup_does_not_accept_incomplete_pages_wrong_marker_or_faults(self):
        note = "GunnAire upload " + str(uuid.uuid4()) + " sha256 " + "a" * 64
        for result in ({"Fault": {}}, {"QueryResponse": {"Attachable": [{"Id": "A1", "Note": note}], "maxResults": 1}},
                       {"QueryResponse": {"Attachable": [], "totalCount": 1}},
                       {"QueryResponse": {"Attachable": [{"Id": "A1", "Note": "other"}], "startPosition": 1, "maxResults": 1}}):
            self.provider.send = lambda _, result=result: result
            with self.assertRaises(uploads.AttemptError):
                self.provider.find(note)
        self.provider.send = lambda _: {"QueryResponse": {}}
        self.assertEqual(self.provider.find(note), [])

    def test_transport_rejects_external_hosts_redirect_paths_mutations_and_query_injection(self):
        for url, method in (("https://outside.invalid/v3/company/realm/upload?minorversion=75", "POST"),
                            ("https://user@quickbooks.api.intuit.com/v3/company/realm/query?minorversion=75", "GET"),
                            ("https://quickbooks.api.intuit.com:444/v3/company/realm/query?minorversion=75", "GET"),
                            ("https://quickbooks.api.intuit.com/v3/company/realm/invoice?minorversion=75", "POST"),
                            ("https://quickbooks.api.intuit.com/v3/company/realm/attachable/A1?minorversion=75", "DELETE"),
                            ("https://quickbooks.api.intuit.com/v3/company/realm/query?minorversion=75&query=SELECT+*+FROM+Customer", "GET"),
                            ("https://quickbooks.api.intuit.com/v3/company/realm/invoice/D1?minorversion=75&minorversion=75", "GET")):
            with mock.patch.object(urllib.request, "build_opener") as opener:
                with self.assertRaises(uploads.AttemptError):
                    adapter.transport(urllib.request.Request(url, method=method))
                opener.assert_not_called()
        self.assertIsNone(adapter.NoRedirect().redirect_request(None, None, 302, "", {}, "https://outside.invalid"))

    def test_transport_bounds_and_sanitizes_provider_responses(self):
        request = urllib.request.Request("https://quickbooks.api.intuit.com/v3/company/realm/invoice/D1?minorversion=75")
        for raw in (b"private invalid data", b"a" * (1024 * 1024 + 1), b'{"Invoice":{},"Invoice":{}}', b'{"Invoice":NaN}'):
            response = mock.MagicMock(); response.status = 200; response.read.return_value = raw
            response.__enter__.return_value = response
            with mock.patch.object(urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = response
                with self.assertRaises(uploads.AttemptError) as caught:
                    adapter.transport(request)
                self.assertNotIn("private invalid", str(caught.exception))
                response.read.assert_called_once_with(1024 * 1024 + 1)


if __name__ == "__main__":
    unittest.main()
