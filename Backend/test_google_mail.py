from __future__ import annotations

import copy
import io
import json
import sqlite3
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from email import policy
from email.parser import BytesParser
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from Backend import google_mail as mail
from Backend import google_connections as google
from Backend import gunnaire_backend as backend
from Backend import test_google_connections


class GoogleMailTests(unittest.TestCase):
    def setUp(self):
        # Reuse OAuth fixture setup without inheriting/rerunning its test methods.
        self.fixture = test_google_connections.GoogleConnectionTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.grant = self.fixture.connect()
        self.calls = []
        self.messages = {"message1": self.message("message1", "thread1")}
        self.on_request = lambda *args: None
        self.after_post = lambda *args: None
        self.override = None
        self.service = mail.GoogleMail(self.fixture.service, request_transport=self.transport)
        self.identifier = str(uuid.uuid4())
        self.outgoing = {"to": ["customer@example.invalid"], "subject": "Service appointment", "body": "Your appointment is confirmed.\nSecond line.\n",
            "attachments": [{"name": "service.pdf", "mimeType": "application/pdf", "data": mail.encoded(b"fixture-pdf-bytes")}]}

    @staticmethod
    def message(identifier, thread, labels=None):
        return {"id": identifier, "threadId": thread, "labelIds": labels if labels is not None else ["INBOX", "UNREAD"],
            "snippet": "Simple message", "internalDate": "1788828000000", "payload": {"mimeType": "text/plain", "headers": [
                {"name": "From", "value": "customer@example.invalid"}, {"name": "Subject", "value": "Service appointment"},
                {"name": "Message-ID", "value": "<parent@example.invalid>"}, {"name": "Received", "value": "private-routing-detail"}],
                "body": {"size": 5, "data": mail.encoded(b"Hello")}}}

    def context(self, role="Admin", grant=None):
        return self.service.context(self.fixture.sessions[role], self.fixture.company, grant or self.grant)

    def transport(self, method, resource, token, **kwargs):
        self.assertEqual(token, "fixture-access")
        self.calls.append((method, resource, copy.deepcopy(kwargs)))
        self.on_request(method, resource, kwargs)
        if self.override is not None:
            return copy.deepcopy(self.override)
        if resource == "messages" and method == "GET":
            query = kwargs.get("query", {})
            messages = list(self.messages.values())
            if "rfc822msgid:" in query.get("q", ""):
                expected = query["q"].split("rfc822msgid:", 1)[1]
                messages = [value for value in messages if value.get("raw") and
                    str(BytesParser(policy=policy.default).parsebytes(mail.decoded(value["raw"], mail.MAX_MESSAGE_BYTES))["Message-ID"]) == expected]
            label = query.get("labelIds")
            if label:
                messages = [value for value in messages if label in value["labelIds"]]
            return {"messages": [{"id": value["id"], "threadId": value["threadId"]} for value in messages]}
        if resource == "messages/send" and method == "POST":
            result = self.message("sent1", kwargs["body"].get("threadId", "sentthread"), ["SENT"])
            result["raw"] = kwargs["body"]["raw"]
            self.messages["sent1"] = result
            accepted = {"id": result["id"], "threadId": result["threadId"]}
            self.after_post(method, resource, kwargs)
            return accepted
        parts = resource.split("/")
        if parts[0] == "messages" and len(parts) >= 2:
            value = self.messages.get(parts[1])
            if value is None:
                raise mail.failure("mail_rejected", 502)
            if method == "GET" and len(parts) == 2:
                result = copy.deepcopy(value)
                if kwargs.get("query", {}).get("format") == "metadata":
                    result.get("payload", {}).pop("body", None)
                    result.pop("raw", None)
                return result
            if method == "GET" and len(parts) == 4 and parts[2] == "attachments":
                return {"size": 7, "data": mail.encoded(b"fixture")}
            if method == "POST":
                labels = set(value["labelIds"])
                if parts[2] == "trash":
                    labels.add("TRASH")
                elif parts[2] == "untrash":
                    labels.discard("TRASH")
                else:
                    labels.update(kwargs["body"]["addLabelIds"])
                    labels.difference_update(kwargs["body"]["removeLabelIds"])
                value["labelIds"] = sorted(labels)
                self.after_post(method, resource, kwargs)
                return copy.deepcopy(value)
        raise AssertionError("Unexpected fixture provider route")

    def assert_code(self, code, action):
        with self.assertRaises(google.ConnectionError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def prepare(self):
        return self.service.prepare_send(self.context(), self.identifier, self.outgoing)

    def post_count(self):
        return sum(method == "POST" for method, _, _ in self.calls)

    def test_inbox_lists_metadata_only_and_removes_routing_diagnostics(self):
        result = self.service.page(self.context())
        self.assertEqual(result["actorEmail"], "admin@example.invalid")
        self.assertEqual(result["companyID"], self.fixture.company)
        self.assertEqual(result["grantID"], self.grant)
        self.assertEqual(len(result["messages"]), 1)
        self.assertNotIn("private-routing-detail", json.dumps(result))
        self.assertEqual(self.calls[1][2]["query"]["format"], "metadata")
        self.assertEqual(self.post_count(), 0)

    def test_current_office_role_and_exact_company_grant_required(self):
        for role in ("Field Technician", "Accounting", "Standard"):
            with self.subTest(role=role):
                with self.assertRaises(google.ConnectionError):
                    self.context(role)
        with self.assertRaises(google.ConnectionError):
            self.service.context(self.fixture.admin, str(uuid.uuid4()), self.grant)
        with self.assertRaises(google.ConnectionError):
            self.context(grant=str(uuid.uuid4()))
        self.assertEqual(self.calls, [])

    def test_paging_rejects_repeated_tokens_duplicate_ids_and_foreign_threads(self):
        cases = [({"messages": [], "nextPageToken": "same"}, "same"),
            ({"messages": [{"id": "message1", "threadId": "thread1"}] * 2}, None),
            ({"messages": [{"id": "../other", "threadId": "thread1"}]}, None)]
        for reply, token in cases:
            self.override = reply
            with self.assertRaises(google.ConnectionError):
                self.service.page(self.context(), page_token=token)
        self.override = None
        original = self.transport
        def wrong_thread(method, resource, token, **kwargs):
            result = original(method, resource, token, **kwargs)
            if resource == "messages/message1":
                result["threadId"] = "other"
            return result
        self.service.transport = wrong_thread
        self.assert_code("mail_unconfirmed", lambda: self.service.page(self.context()))

    def test_access_and_role_changes_reject_late_pages(self):
        context = self.context()
        def revoke(*args):
            with backend.db() as connection:
                connection.execute("UPDATE users SET role='Dispatcher' WHERE email='admin@example.invalid'")
        self.on_request = revoke
        self.assert_code("mail_access", lambda: self.service.page(context))
        self.assertEqual(len(self.calls), 1)

    def test_reconnect_during_fanout_never_reads_under_replacement_grant(self):
        context = self.context()
        def replace(*args):
            with backend.db() as connection:
                connection.execute("UPDATE google_connections SET id=?", (str(uuid.uuid4()),))
        self.on_request = replace
        self.assert_code("connection_changed", lambda: self.service.page(context))
        self.assertEqual(len(self.calls), 1)

    def test_attachment_requires_exact_advertised_parent_id_and_size(self):
        self.messages["message1"]["payload"]["parts"] = [{"mimeType": "application/pdf", "filename": "file.pdf",
            "body": {"attachmentId": "attachment1", "size": 7}}]
        result = self.service.attachment(self.context(), "message1", "attachment1")
        self.assertEqual(mail.decoded(result["body"]["data"], 100), b"fixture")
        with self.assertRaises(google.ConnectionError):
            self.service.attachment(self.context(), "message1", "other")
        self.messages["message1"]["payload"]["parts"][0]["body"]["size"] = 8
        self.assert_code("mail_unconfirmed", lambda: self.service.attachment(self.context(), "message1", "attachment1"))

    def test_mailbox_actions_confirm_exact_target_and_never_permanently_delete(self):
        for action in mail.ACTIONS:
            result = self.service.action(self.context(), str(uuid.uuid4()), message="message1", thread="thread1", action=action)
            self.assertEqual(result["state"], "confirmed")
            self.assertEqual(result["message"]["id"], "message1")
        self.assertEqual(self.post_count(), 5)
        self.assertFalse(any(method == "DELETE" for method, _, _ in self.calls))

    def test_lost_action_reply_is_recovered_without_posting_again(self):
        def lost(*args):
            raise mail.failure("mail_unconfirmed", 502)
        self.after_post = lost
        with self.assertRaises(google.ConnectionError):
            self.service.action(self.context(), self.identifier, message="message1", thread="thread1", action="trash")
        self.after_post = lambda *args: None
        result = self.service.action(self.context(), self.identifier, message="message1", thread="thread1", action="trash")
        self.assertEqual(result["state"], "confirmed")
        self.assertEqual(self.post_count(), 1)

    def test_action_cannot_switch_original_message_thread_or_desired_state(self):
        self.service.action(self.context(), self.identifier, message="message1", thread="thread1", action="read")
        for message, thread, action in (("other", "thread1", "read"), ("message1", "other", "read"), ("message1", "thread1", "trash")):
            self.assert_code("mail_changed", lambda: self.service.action(self.context(), self.identifier, message=message, thread=thread, action=action))
        self.assertEqual(self.post_count(), 1)

    def test_prepare_is_immutable_and_encrypts_message_recipient_and_file_bytes(self):
        self.assertEqual(self.prepare()["state"], "prepared")
        self.prepare()
        self.outgoing["subject"] = "Changed"
        self.assert_code("mail_changed", self.prepare)
        with backend.db() as connection:
            rows = connection.execute("SELECT * FROM google_mail_operations").fetchall()
        self.assertEqual(len(rows), 1)
        plain = json.dumps(dict(rows[0]))
        for private in ("customer@example.invalid", "Service appointment", "fixture-pdf-bytes", "service.pdf", "Your appointment"):
            self.assertNotIn(private, plain)
        self.assertEqual(self.calls, [])

    def test_encrypted_content_cannot_be_copied_to_another_operation(self):
        self.prepare()
        other = str(uuid.uuid4())
        self.service.prepare_send(self.context(), other, self.outgoing)
        with backend.db() as connection:
            cipher = connection.execute("SELECT secrets_ciphertext FROM google_mail_operations WHERE id=?", (other,)).fetchone()[0]
            connection.execute("UPDATE google_mail_operations SET secrets_ciphertext=? WHERE id=?", (cipher, self.identifier))
        self.assert_code("storage_unavailable", lambda: self.service.send(self.context(), self.identifier))
        self.assertEqual(self.calls, [])

    def test_send_verifies_original_mime_and_keeps_single_dispatch(self):
        self.prepare()
        result = self.service.send(self.context(), self.identifier)
        self.assertEqual(result["state"], "confirmed")
        self.assertEqual(result["messageID"], "sent1")
        self.assertEqual(self.service.send(self.context(), self.identifier), result)
        self.assertEqual(self.post_count(), 1)

    def test_lost_send_reply_recovers_exact_message_without_another_send(self):
        self.prepare()
        self.after_post = lambda *args: (_ for _ in ()).throw(mail.failure("mail_unconfirmed", 502))
        with self.assertRaises(google.ConnectionError):
            self.service.send(self.context(), self.identifier)
        self.assertEqual(self.service.outcome(self.context(), self.identifier)["state"], "review")
        self.after_post = lambda *args: None
        recovered_service = mail.GoogleMail(self.fixture.make_service(), request_transport=self.transport)
        result = recovered_service.recover_send(self.context(), self.identifier)
        self.assertEqual(result["state"], "confirmed")
        self.assertEqual(self.post_count(), 1)
        self.assertTrue(any("rfc822msgid:" in call[2].get("query", {}).get("q", "") for call in self.calls))

    def test_no_search_result_or_duplicates_never_authorize_resending(self):
        self.prepare()
        self.service.claim(self.context(), self.identifier)  # Simulated interrupted process.
        self.assert_code("mail_unconfirmed", lambda: self.service.recover_send(self.context(), self.identifier))
        self.service.send(self.context(), self.identifier)
        self.assertEqual(self.post_count(), 0)
        self.override = {"messages": [{"id": "a", "threadId": "a"}, {"id": "b", "threadId": "b"}]}
        self.assert_code("mail_unconfirmed", lambda: self.service.recover_send(self.context(), self.identifier))
        self.assertEqual(self.post_count(), 0)

    def test_failed_verification_get_never_turns_acceptance_into_rejection(self):
        self.prepare()
        def fail_read(method, resource, kwargs):
            if method == "GET":
                raise mail.failure("mail_rejected", 502)
        self.on_request = fail_read
        with self.assertRaises(google.ConnectionError):
            self.service.send(self.context(), self.identifier)
        row = self.service.outcome(self.context(), self.identifier)
        self.assertEqual(row["state"], "review")
        self.assertEqual(row["messageID"], "sent1")
        self.service.send(self.context(), self.identifier)
        self.assertEqual(self.post_count(), 1)

    def test_definite_send_rejection_is_retained_without_automatic_replay(self):
        self.prepare()
        self.on_request = lambda *args: (_ for _ in ()).throw(mail.failure("mail_rejected", 502))
        with self.assertRaises(google.ConnectionError):
            self.service.send(self.context(), self.identifier)
        self.assertEqual(self.service.outcome(self.context(), self.identifier)["state"], "rejected")
        self.service.send(self.context(), self.identifier)
        self.assertEqual(self.post_count(), 1)

    def test_changed_mime_content_cannot_confirm_a_similar_sent_message(self):
        for change in ("body", "to", "subject", "attachments"):
            with self.subTest(change=change):
                self.identifier = str(uuid.uuid4())
                self.prepare()
                def tamper(method, resource, kwargs):
                    changed = copy.deepcopy(self.outgoing)
                    if change == "attachments":
                        changed[change][0]["data"] = mail.encoded(b"different-file")
                    elif change == "to":
                        changed[change] = ["different@example.invalid"]
                    else:
                        changed[change] = "different"
                    raw = self.service.raw_message("admin@example.invalid", self.identifier, changed, self.fixture.now)
                    self.messages["sent1"]["raw"] = mail.encoded(raw)
                self.after_post = tamper
                self.assert_code("mail_unconfirmed", lambda: self.service.send(self.context(), self.identifier))
                self.assertEqual(self.service.outcome(self.context(), self.identifier)["state"], "review")

    def test_cancel_before_send_prevents_dispatch_and_cannot_erase_accepted_send(self):
        self.prepare()
        self.assertEqual(self.service.cancel(self.context(), self.identifier)["state"], "cancelled")
        self.service.send(self.context(), self.identifier)
        self.assertEqual(self.post_count(), 0)
        self.identifier = str(uuid.uuid4())
        self.prepare()
        self.service.send(self.context(), self.identifier)
        self.assertEqual(self.service.cancel(self.context(), self.identifier)["state"], "confirmed")

    def test_concurrent_workers_dispatch_once(self):
        self.prepare()
        entered, release = threading.Event(), threading.Event()
        def hold(method, resource, kwargs):
            if method == "POST":
                entered.set()
                self.assertTrue(release.wait(5))
        self.on_request = hold
        with ThreadPoolExecutor(max_workers=2) as executor:
            first = executor.submit(lambda: self.service.send(self.context(), self.identifier))
            self.assertTrue(entered.wait(5))
            try:
                second = self.service.send(self.context(), self.identifier)
                self.assertEqual(second["state"], "dispatching")
            finally:
                release.set()
            self.assertEqual(first.result(5)["state"], "confirmed")
        self.assertEqual(self.post_count(), 1)

    def test_revoke_during_send_retains_dispatch_lock_and_rejects_late_result(self):
        self.prepare()
        def revoke(*args):
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE id=?", (self.fixture.now.isoformat(), self.fixture.admin))
        self.after_post = revoke
        self.assert_code("access_required", lambda: self.service.send(self.context(), self.identifier))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT state FROM google_mail_operations WHERE id=?", (self.identifier,)).fetchone()[0], "dispatching")
        self.assertEqual(self.post_count(), 1)

    def test_audit_failure_prevents_unrecorded_dispatch(self):
        self.prepare()
        original_audit = self.fixture.service.audit
        def fail(actor, action, *args, **kwargs):
            if action == "dispatch":
                raise sqlite3.OperationalError("fixture audit unavailable")
            return original_audit(actor, action, *args, **kwargs)
        self.fixture.service.audit = fail
        with self.assertRaises(sqlite3.OperationalError):
            self.service.send(self.context(), self.identifier)
        self.assertEqual(self.service.outcome(self.context(), self.identifier)["state"], "prepared")
        self.assertEqual(self.post_count(), 0)

    def test_confirmation_audit_failure_preserves_accepted_identity_for_recovery(self):
        self.prepare()
        original_audit = self.fixture.service.audit
        def fail(actor, action, *args, **kwargs):
            if action == "confirmed":
                raise sqlite3.OperationalError("fixture audit unavailable")
            return original_audit(actor, action, *args, **kwargs)
        self.fixture.service.audit = fail
        with self.assertRaises(sqlite3.OperationalError):
            self.service.send(self.context(), self.identifier)
        self.assertEqual(self.service.outcome(self.context(), self.identifier)["messageID"], "sent1")
        self.fixture.service.audit = original_audit
        self.assertEqual(self.service.recover_send(self.context(), self.identifier)["state"], "confirmed")
        self.assertEqual(self.post_count(), 1)

    def test_invalid_recipients_headers_file_paths_and_business_injection_fail_before_network(self):
        invalid = [{**self.outgoing, "to": ["x\r\nBcc:private@example.invalid"]},
            {**self.outgoing, "to": ["customer@example.invalid"] * 2}, {**self.outgoing, "subject": "x\nBcc:x"},
            {**self.outgoing, "business": {"invoiceID": str(uuid.uuid4())}},
            {**self.outgoing, "attachments": [{"name": "../secret", "mimeType": "application/pdf", "data": "YQ"}]},
            {**self.outgoing, "attachments": [{"name": "ok", "mimeType": "text/plain\r\nX:y", "data": "YQ"}]}]
        for payload in invalid:
            with self.assertRaises(google.ConnectionError):
                self.service.prepare_send(self.context(), self.identifier, payload)
        self.assertEqual(self.calls, [])

    def test_reply_requires_original_parent_and_matching_thread_subject_and_references(self):
        self.outgoing["reply"] = {"parentID": "message1", "threadID": "thread1", "messageID": "<parent@example.invalid>",
            "subject": self.outgoing["subject"], "references": []}
        self.prepare()
        self.assertEqual(self.service.send(self.context(), self.identifier)["threadID"], "thread1")
        self.identifier = str(uuid.uuid4())
        self.outgoing["reply"]["messageID"] = "<forged@example.invalid>"
        self.prepare()
        self.assert_code("mail_changed", lambda: self.service.send(self.context(), self.identifier))
        self.assertEqual(self.post_count(), 1)

    def test_outbox_is_own_grant_scoped_and_lists_only_compact_encrypted_summaries(self):
        self.prepare()
        result = self.service.outbox(self.context())
        self.assertEqual(result["operations"][0]["id"], self.identifier)
        self.assertEqual(result["operations"][0]["summary"]["to"], ["customer@example.invalid"])
        self.assertEqual(result["operations"][0]["summary"]["subject"], self.outgoing["subject"])
        self.assertNotIn("body", json.dumps(result))
        self.assertNotIn(self.outgoing["attachments"][0]["data"], json.dumps(result))

    def test_outbox_list_does_not_decrypt_every_attachment_but_explicit_open_preserves_it(self):
        self.prepare()
        original_open = self.fixture.service.open
        kinds = []
        def observed(kind, row):
            kinds.append(kind)
            return original_open(kind, row)
        self.fixture.service.open = observed
        self.service.outbox(self.context())
        self.assertEqual(kinds, ["mail-summary"])
        opened = self.service.saved_message(self.context(), self.identifier)
        self.assertEqual(opened["message"], self.outgoing)
        self.assertIn("mail-operation", kinds)

    def test_modified_summary_ciphertext_cannot_hide_a_different_message(self):
        self.prepare()
        other = str(uuid.uuid4())
        self.service.prepare_send(self.context(), other, {**self.outgoing, "subject": "Other original"})
        with backend.db() as connection:
            ciphertext = connection.execute("SELECT summary_ciphertext FROM google_mail_operations WHERE id=?", (other,)).fetchone()[0]
            connection.execute("UPDATE google_mail_operations SET summary_ciphertext=? WHERE id=?", (ciphertext, self.identifier))
        self.assert_code("storage_unavailable", lambda: self.service.outbox(self.context()))

    def test_summary_upgrade_preserves_original_outbox_body(self):
        self.prepare()
        with backend.db() as connection:
            connection.execute("UPDATE google_mail_operations SET summary_ciphertext=NULL WHERE id=?", (self.identifier,))
            mail.initialize_schema(connection)
        self.assertEqual(self.service.outbox(self.context())["operations"][0]["summary"]["subject"], self.outgoing["subject"])
        self.assertEqual(self.service.saved_message(self.context(), self.identifier)["message"], self.outgoing)

    def test_retained_body_and_metadata_survive_consistent_database_backup(self):
        self.prepare()
        destination = Path(self.fixture.directory.name) / "restore.sqlite3"
        with backend.db() as source, sqlite3.connect(destination) as target:
            source.backup(target)
        with mock.patch.object(backend, "DB_PATH", destination):
            restored = mail.GoogleMail(self.fixture.make_service(), request_transport=self.transport)
            context = restored.context(self.fixture.admin, self.fixture.company, self.grant)
            self.assertEqual(restored.saved_message(context, self.identifier)["message"], self.outgoing)
            self.assertEqual(restored.outcome(context, self.identifier)["state"], "prepared")
        self.assertEqual(self.post_count(), 0)

    def test_charset_tampering_changes_the_verified_message_signature(self):
        raw = self.service.raw_message("admin@example.invalid", self.identifier, self.outgoing, self.fixture.now)
        changed = BytesParser(policy=policy.default).parsebytes(raw)
        changed.get_body(preferencelist=("plain",)).set_param("charset", "iso-8859-1", header="Content-Type", replace=True)
        self.assertNotEqual(mail.GoogleMail.mime_signature(raw), mail.GoogleMail.mime_signature(changed.as_bytes(policy=policy.SMTP)))

    def test_expired_request_budget_and_missing_mail_scope_prevent_provider_contact(self):
        context = self.context()
        context.deadline = 0
        self.assert_code("mail_unconfirmed", lambda: self.service.page(context))
        with backend.db() as connection:
            connection.execute("UPDATE google_connections SET scopes_json='[]' WHERE id=?", (self.grant,))
        self.assert_code("scope_required", self.context)
        self.assertEqual(self.calls, [])

    def test_invalid_unicode_and_automated_business_context_are_explicitly_rejected(self):
        self.assert_code("invalid_mail", lambda: self.service.prepare_send(self.context(), self.identifier, {**self.outgoing, "subject": "\ud800"}))
        self.assert_code("mail_business_review", lambda: self.service.prepare_send(self.context(), self.identifier, {**self.outgoing, "business": {"invoiceID": str(uuid.uuid4())}}))
        self.assertEqual(self.calls, [])

    def test_malformed_provider_message_is_an_unconfirmed_provider_reply_not_bad_user_input(self):
        self.override = {"id": [], "threadId": "thread1"}
        with self.assertRaises(google.ConnectionError) as caught:
            self.service.message(self.context(), "message1")
        self.assertEqual(caught.exception.code, "mail_unconfirmed")
        self.assertEqual(caught.exception.status, 502)

    def test_another_staff_login_cannot_recover_or_cancel_the_original_outbox(self):
        self.prepare()
        # A distinct staff actor may have a valid own connection, never this one.
        with backend.db() as connection:
            original = connection.execute("SELECT * FROM google_connections WHERE id=?", (self.grant,)).fetchone()
            columns = list(original.keys())
            values = dict(original)
            values["id"] = str(uuid.uuid4())
            values["actor_email"] = "dispatcher@example.invalid"
            values["subject"] = "subject-Dispatcher"
            connection.execute("INSERT INTO google_connections (" + ",".join(columns) + ") VALUES (" + ",".join("?" for _ in columns) + ")", [values[key] for key in columns])
        other = self.context("Dispatcher", grant=values["id"])
        self.assert_code("mail_access", lambda: self.service.outcome(other, self.identifier))
        self.assert_code("mail_access", lambda: self.service.cancel(other, self.identifier))
        self.assertEqual(self.service.outbox(other)["operations"], [])
        self.assertEqual(self.calls, [])

    def test_outbox_pagination_returns_each_original_once(self):
        identifiers = []
        for _ in range(29):
            self.fixture.now += timedelta(seconds=1)
            identifier = str(uuid.uuid4())
            self.service.prepare_send(self.context(), identifier, self.outgoing)
            identifiers.append(identifier)
        first = self.service.outbox(self.context())
        second = self.service.outbox(self.context(), before=first["nextPageToken"])
        self.assertEqual(len(first["operations"]), 25)
        self.assertEqual(len(second["operations"]), 4)
        actual = [value["id"] for value in first["operations"] + second["operations"]]
        self.assertEqual(actual, list(reversed(identifiers)))
        self.assertIsNone(second["nextPageToken"])
        self.assert_code("mail_changed", lambda: self.service.outbox(self.context(), before=first["nextPageToken"] + "tampered"))
        with backend.db() as connection:
            new_grant = str(uuid.uuid4())
            connection.execute("UPDATE google_connections SET id=? WHERE id=?", (new_grant, self.grant))
        self.assert_code("mail_changed", lambda: self.service.outbox(self.context(grant=new_grant), before=first["nextPageToken"]))

    def test_unicode_subject_filename_and_binary_bytes_survive_exact_mime_verification(self):
        self.outgoing["subject"] = "Réparation — chaudière"
        self.outgoing["body"] = "L’été, 75 °F\n\n"
        self.outgoing["attachments"] = [{"name": "pièce-été.pdf", "mimeType": "application/pdf", "data": mail.encoded(bytes(range(256)))}]
        self.prepare()
        self.assertEqual(self.service.send(self.context(), self.identifier)["state"], "confirmed")
        original = BytesParser(policy=policy.default).parsebytes(mail.decoded(self.messages["sent1"]["raw"], mail.MAX_MESSAGE_BYTES))
        self.assertEqual(str(original["Subject"]), self.outgoing["subject"])
        attachment = list(original.iter_attachments())[0]
        self.assertEqual(attachment.get_filename(), "pièce-été.pdf")
        self.assertEqual(attachment.get_payload(decode=True), bytes(range(256)))

    def test_bad_provider_raw_missing_sent_label_and_wrong_ids_keep_send_unconfirmed(self):
        for mutation in (lambda value: value.update(raw="invalid-raw"), lambda value: value.update(labelIds=["INBOX"]),
                         lambda value: value.update(id="different"), lambda value: value.update(threadId="different")):
            with self.subTest(mutation=mutation):
                self.identifier = str(uuid.uuid4())
                self.prepare()
                self.after_post = lambda *args: mutation(self.messages["sent1"])
                with self.assertRaises(google.ConnectionError):
                    self.service.send(self.context(), self.identifier)
                self.assertNotEqual(self.service.outcome(self.context(), self.identifier)["state"], "confirmed")

    def test_missing_google_key_never_replaces_or_clears_saved_outbox(self):
        self.prepare()
        with backend.db() as connection:
            original = dict(connection.execute("SELECT * FROM google_mail_operations WHERE id=?", (self.identifier,)).fetchone())
        self.fixture.service.encryption_key = ""
        self.assert_code("not_configured", lambda: self.service.send(self.context(), self.identifier))
        with backend.db() as connection:
            self.assertEqual(dict(connection.execute("SELECT * FROM google_mail_operations WHERE id=?", (self.identifier,)).fetchone()), original)
        self.assertEqual(self.calls, [])

    def test_structured_http_routes_require_application_session_and_scope_and_retain_original(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        def request(route, payload=None, token=None, raw=None):
            headers = {"Authorization": "Bearer " + (token or self.fixture.tokens["Admin"])}
            body = raw if raw is not None else json.dumps(payload).encode() if payload is not None else None
            req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/api/google/mail/" + route,
                headers=headers, data=body)
            try:
                response = urllib.request.urlopen(req, timeout=5)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                return response.status, response.headers, json.load(response)
        scope = {"companyID": self.fixture.company, "grantID": self.grant}
        query = urllib.parse.urlencode(scope)
        try:
            with mock.patch.object(backend.GunnAireBackendHandler, "google_mail_service", return_value=self.service), mock.patch("builtins.print") as printed:
                code, headers, result = request("messages?" + query + "&query=private%40example.invalid")
                self.assertEqual(code, 200)
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertEqual(result["actorEmail"], "admin@example.invalid")
                self.assertEqual(request("messages?" + query, token="invalid-session")[0], 401)
                self.assertEqual(request("messages?" + query + "&companyID=duplicate")[0], 400)
                self.assertEqual(request("messages?" + query + "&userId=another")[0], 400)
                self.assertEqual(request("messages?" + query, token=self.fixture.tokens["Standard"])[0], 403)
                self.assertEqual(request("outbox", raw=b'{"companyID":"a","companyID":"b","grantID":"c"}')[0], 400)
                self.assertEqual(request("outbox", {**scope, "id": self.identifier, "message": self.outgoing})[0], 200)
                self.assertEqual(request("operations/" + self.identifier + "/send", scope)[2]["state"], "confirmed")
                self.assertEqual(request("operations/" + self.identifier + "/send", scope)[2]["state"], "confirmed")
                self.assertEqual(request("operations/" + self.identifier + "/recovery?" + query)[2]["state"], "confirmed")
                self.assertEqual(request("messages/message1/actions", {**scope, "id": str(uuid.uuid4()), "threadID": "thread1", "action": "trash"})[2]["state"], "confirmed")
                self.assertEqual(request("messages/message1?" + query)[2]["message"]["id"], "message1")
                self.assertEqual(request("messages/message1/delete", scope)[0], 400)
                self.assertNotIn("private%40", str(printed.call_args_list))
                self.assertNotIn("fixture-access", json.dumps(result))
            self.assertEqual(self.post_count(), 2)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(5)

    def test_mail_access_log_redacts_search_terms_and_provider_ids(self):
        handler = object.__new__(backend.GunnAireBackendHandler)
        handler.client_address = ("127.0.0.1", 0)
        with mock.patch("builtins.print") as printed:
            handler.log_message('"GET %s HTTP/1.1" 200 -', "/api/google/mail/messages/private-id?query=private%40example.invalid")
        output = str(printed.call_args_list)
        self.assertNotIn("private", output)
        self.assertIn("/api/google/mail/[redacted]", output)


class GoogleMailTransportTests(unittest.TestCase):
    def test_fixed_origin_no_redirects_bounded_read_and_no_retry(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b'{"messages":[]}'
        opener = mock.Mock()
        opener.open.return_value = response
        with mock.patch.object(urllib.request, "build_opener", return_value=opener) as build:
            result = mail.transport("GET", "messages", "fixture-secret", query={"q": "a&userId=other", "maxResults": 25}, maximum=64)
        self.assertEqual(result, {"messages": []})
        self.assertEqual(build.call_args.args, (google.NoRedirect,))
        request = opener.open.call_args.args[0]
        self.assertEqual(urllib.parse.urlsplit(request.full_url).netloc, "gmail.googleapis.com")
        self.assertTrue(urllib.parse.urlsplit(request.full_url).path.startswith("/gmail/v1/users/me/"))
        self.assertEqual(urllib.parse.parse_qs(urllib.parse.urlsplit(request.full_url).query)["q"], ["a&userId=other"])
        response.read.assert_called_once_with(65)
        self.assertEqual(opener.open.call_count, 1)

    def test_hostile_routes_oversized_duplicate_json_and_error_body_are_rejected(self):
        for route in ("https://attacker.invalid", "../users/other/messages", "messages/x%2fy", "messages/x/delete", "messages?user=other"):
            with self.assertRaises(google.ConnectionError):
                mail.transport("POST", route, "fixture-secret")
        for data in (b'{"id":"a","id":"b"}', b'x' * 65, b'[]'):
            response = mock.MagicMock()
            response.__enter__.return_value = response
            response.status = 200
            response.read.return_value = data
            opener = mock.Mock()
            opener.open.return_value = response
            with mock.patch.object(urllib.request, "build_opener", return_value=opener), self.assertRaises(google.ConnectionError):
                mail.transport("GET", "messages", "fixture-secret", maximum=64)
        opener.open.side_effect = urllib.error.HTTPError(mail.ROOT, 403, "private-provider-error", {}, io.BytesIO(b"private body"))
        with mock.patch.object(urllib.request, "build_opener", return_value=opener), self.assertRaises(google.ConnectionError) as caught:
            mail.transport("POST", "messages/send", "fixture-secret", body={"raw": "private"})
        self.assertEqual(caught.exception.code, "mail_rejected")
        self.assertNotIn("private", str(caught.exception))
