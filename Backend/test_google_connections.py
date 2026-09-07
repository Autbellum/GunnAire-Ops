from __future__ import annotations

import base64
import copy
import hashlib
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
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet
from Backend import gunnaire_backend as backend
from Backend import google_connections as google


class GoogleConnectionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.key = Fernet.generate_key().decode()
        self.settings = mock.patch.multiple(backend, DB_PATH=root / "fixture.sqlite3", STORAGE_ROOT=root / "files",
            DATA_ROOT=root, AUTH_MODE="google-id-token", PRIMARY_ADMIN_EMAIL="owner@example.invalid",
            GOOGLE_WEB_CLIENT_ID="fixture-web.apps.googleusercontent.com", GOOGLE_WEB_CLIENT_SECRET="fixture-confidential-secret",
            GOOGLE_WEB_REDIRECT_URI="https://backend.example.invalid/api/google/oauth/callback",
            GOOGLE_TOKEN_ENCRYPTION_KEY=self.key, GOOGLE_ALLOWED_DOMAIN="example.invalid")
        self.settings.start()
        backend.initialize_database()
        self.now = datetime.now(timezone.utc)
        self.tokens, self.sessions = {}, {}
        with backend.db() as connection:
            self.company = connection.execute("SELECT company_id FROM company_identity").fetchone()[0]
            for role in (*sorted(google.ROLES), "Standard"):
                email = role.lower().replace(" ", ".") + "@example.invalid"
                connection.execute("INSERT INTO users VALUES (?,?,1,?,?)", (email, role, self.now.isoformat(), self.now.isoformat()))
        for role in (*sorted(google.ROLES), "Standard"):
            self.tokens[role] = backend.create_app_session(role.lower().replace(" ", ".") + "@example.invalid", "google", "subject-" + role)[0]
            with backend.db() as connection:
                self.sessions[role] = connection.execute("SELECT id FROM auth_sessions WHERE token_hash=?", (backend.app_session_token_hash(self.tokens[role]),)).fetchone()[0]
        # create_app_session uses the real clock; the injectable clock must not precede it.
        self.now = datetime.now(timezone.utc)
        self.calls, self.claim_changes = [], {}
        self.before_exchange = lambda: None
        self.before_refresh = lambda: None
        self.token_changes = {}
        self.service = self.make_service()
        self.admin = self.sessions["Admin"]
        self.request_payload = {"id": str(uuid.uuid4()), "companyID": self.company, "features": ["mail"]}

    def make_service(self, database=None):
        return google.GoogleConnections(database or backend.db, backend.record_audit_event,
            client_id=backend.GOOGLE_WEB_CLIENT_ID, client_secret=backend.GOOGLE_WEB_CLIENT_SECRET,
            redirect_uri=backend.GOOGLE_WEB_REDIRECT_URI, encryption_key=self.key, allowed_domain="example.invalid",
            transport=self.transport, claims=self.claims, now=lambda: self.now)

    def tearDown(self):
        self.settings.stop()
        self.directory.cleanup()

    def transport(self, form):
        self.calls.append(copy.deepcopy(form))
        if form["grant_type"] == "authorization_code":
            self.before_exchange()
        else:
            self.before_refresh()
        return {"access_token": "fixture-access", "refresh_token": "fixture-refresh", "token_type": "Bearer",
            "expires_in": 3600, "scope": " ".join(sorted(google.IDENTITY_SCOPES | google.FEATURE_SCOPES["mail"])),
            "id_token": "fixture-id-token-" * 10, **self.token_changes}

    def claims(self, token, audience):
        self.assertEqual(audience, backend.GOOGLE_WEB_CLIENT_ID)
        self.assertEqual(token, "fixture-id-token-" * 10)
        return {"iss": "https://accounts.google.com", "aud": audience, "sub": "subject-Admin", "nonce": self.query["nonce"][0],
            "email": "admin@example.invalid", "hd": "example.invalid", "email_verified": True, **self.claim_changes}

    def start(self, *, role="Admin", payload=None):
        result = self.service.start(self.sessions[role], payload or self.request_payload)
        self.query = urllib.parse.parse_qs(urllib.parse.urlsplit(result["authorizationURL"]).query)
        return result

    def callback_query(self, **changes):
        return urllib.parse.urlencode({"state": self.query["state"][0], "code": "fixture-authorization-code", **changes})

    def connect(self):
        self.start()
        result = self.service.callback(self.callback_query())
        self.assertEqual(result["state"], "connected")
        return self.service.status(self.admin, self.company)["id"]

    def assert_code(self, code, action):
        with self.assertRaises(google.ConnectionError) as caught:
            action()
        self.assertEqual(caught.exception.code, code)

    def test_start_is_scoped_pkce_protected_and_idempotent_without_token_exposure(self):
        first = self.start()
        self.assertEqual(first, self.start())
        self.assertEqual(urllib.parse.urlsplit(first["authorizationURL"]).netloc, "accounts.google.com")
        self.assertEqual(self.query["redirect_uri"], [backend.GOOGLE_WEB_REDIRECT_URI])
        self.assertEqual(self.query["access_type"], ["offline"])
        self.assertEqual(self.query["prompt"], ["consent"])
        self.assertEqual(self.query["code_challenge_method"], ["S256"])
        self.assertNotIn("client_secret", self.query)
        self.assertNotIn("code_verifier", self.query)
        self.assertNotIn("fixture-confidential-secret", json.dumps(first))
        with backend.db() as connection:
            row = connection.execute("SELECT * FROM google_oauth_attempts").fetchone()
            secret = self.service.open("attempt", row)
            self.assertNotIn(secret["verifier"], row["secrets_ciphertext"])
            self.assertNotIn(secret["state"], row["state_hash"])
            digest = base64.urlsafe_b64encode(hashlib.sha256(secret["verifier"].encode()).digest()).decode().rstrip("=")
            self.assertEqual(self.query["code_challenge"], [digest])
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM audit_events WHERE subject_type='google-connection'").fetchone()[0], 1)

    def test_invalid_feature_company_actor_and_changed_replay_fail_closed(self):
        for features in ([], ["all"], ["mail", "mail"], "mail", [True], [[]]):
            self.assert_code("invalid_request", lambda: self.start(payload={**self.request_payload, "features": features}))
        self.assert_code("company_changed", lambda: self.start(payload={**self.request_payload, "companyID": str(uuid.uuid4())}))
        self.assert_code("access_required", lambda: self.start(role="Standard"))
        self.start()
        self.assert_code("request_changed", lambda: self.start(payload={**self.request_payload, "features": ["drive"]}))
        self.assert_code("request_changed", lambda: self.start(role="Accounting"))
        self.assert_code("request_pending", lambda: self.start(payload={**self.request_payload, "id": str(uuid.uuid4())}))
        self.assertEqual(self.calls, [])

    def test_recent_business_authentication_is_required_for_connect_and_disconnect(self):
        grant_id = self.connect()
        self.now += timedelta(minutes=11)
        self.assert_code("access_required", lambda: self.start(payload={**self.request_payload, "id": str(uuid.uuid4())}))
        self.assert_code("access_required", lambda: self.service.disconnect(self.admin, self.company, grant_id))
        self.assertEqual(self.service.status(self.admin, self.company)["state"], "active")

    def test_success_keeps_provider_credentials_only_in_authenticated_encrypted_storage(self):
        grant_id = self.connect()
        state = self.service.status(self.admin, self.company)
        self.assertEqual(state["features"], ["mail"])
        self.assertNotIn("token", json.dumps(state))
        self.assertEqual(self.service.attempt_status(self.admin, self.request_payload["id"])["grantID"], grant_id)
        self.assertEqual(self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]), "fixture-access")
        with backend.db() as connection:
            row = connection.execute("SELECT * FROM google_connections").fetchone()
            self.assertNotIn("fixture-access", row["secrets_ciphertext"])
            self.assertNotIn("fixture-refresh", row["secrets_ciphertext"])
            self.assertIsNone(connection.execute("SELECT secrets_ciphertext FROM google_oauth_attempts").fetchone()[0])
            self.assertNotIn("fixture-authorization-code", "\n".join(connection.iterdump()))
        self.assertEqual(len(self.calls), 1)

    def test_code_exchange_is_one_time_even_after_provider_reply_loss(self):
        self.start()
        self.before_exchange = lambda: (_ for _ in ()).throw(google.ConnectionError("provider_unconfirmed", "Fixture lost reply", 502))
        self.assert_code("provider_unconfirmed", lambda: self.service.callback(self.callback_query()))
        self.assertEqual(self.service.attempt_status(self.admin, self.request_payload["id"])["state"], "review")
        self.assert_code("request_finished", lambda: self.service.callback(self.callback_query()))
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.service.status(self.admin, self.company)["state"], "disconnected")

    def test_concurrent_callback_processes_cannot_exchange_code_twice(self):
        self.start()
        query = self.callback_query()
        def run(_):
            try:
                return self.make_service().callback(query)["state"]
            except google.ConnectionError as error:
                return error.code
        with ThreadPoolExecutor(max_workers=2) as workers:
            results = list(workers.map(run, range(2)))
        self.assertCountEqual(results, ["connected", "request_finished"])
        self.assertEqual(len(self.calls), 1)

    def test_nonce_audience_issuer_email_subject_and_domain_are_all_verified(self):
        variations = ({"nonce": "wrong"}, {"aud": "other-client"}, {"azp": "other-client"}, {"iss": "https://attacker.invalid"},
            {"email": "other@example.invalid"}, {"email_verified": False}, {"email_verified": 1}, {"hd": "wrong.invalid"}, {"sub": "different-subject"})
        for variation in variations:
            self.request_payload["id"] = str(uuid.uuid4())
            self.start()
            self.claim_changes = variation
            self.assert_code("account_mismatch", lambda: self.service.callback(self.callback_query()))
            self.assertEqual(self.service.status(self.admin, self.company)["state"], "disconnected")

    def test_partial_consent_enables_only_the_actually_granted_features(self):
        self.request_payload["features"] = ["mail", "calendar", "drive"]
        grant_id = self.connect()
        self.assertEqual(self.service.status(self.admin, self.company)["features"], ["mail"])
        self.assert_code("scope_required", lambda: self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["drive"]))

    def test_malformed_token_response_is_never_persisted_as_active(self):
        for changes in ({"refresh_token": None}, {"expires_in": True}, {"expires_in": float("nan")}, {"token_type": "Basic"},
                        {"scope": None}, {"scope": "openid"}, {"access_token": "bad\ntoken"}, {"id_token": "short"}):
            self.request_payload["id"] = str(uuid.uuid4())
            self.start()
            self.token_changes = changes
            with self.assertRaises(google.ConnectionError):
                self.service.callback(self.callback_query())
            self.assertEqual(self.service.status(self.admin, self.company)["state"], "disconnected")

    def test_cancelled_expired_unknown_or_duplicate_callback_parameters_never_contact_google(self):
        self.start()
        for query in (self.callback_query() + "&state=other", self.callback_query(error="access_denied"), "state=x&code=x", self.callback_query(state="x" * 64)):
            with self.assertRaises(google.ConnectionError):
                self.service.callback(query)
        self.now += timedelta(minutes=11)
        self.assert_code("request_finished", lambda: self.service.callback(self.callback_query()))
        self.service.cancel(self.admin, self.request_payload["id"])
        self.assert_code("request_finished", lambda: self.service.callback(self.callback_query()))
        self.assertEqual(self.calls, [])

    def test_user_denial_does_not_discard_the_existing_connection(self):
        grant_id = self.connect()
        self.request_payload["id"] = str(uuid.uuid4())
        self.start()
        result = self.service.callback(urllib.parse.urlencode({"state": self.query["state"][0], "error": "access_denied"}))
        self.assertEqual(result["state"], "denied")
        self.assertEqual(self.service.status(self.admin, self.company)["id"], grant_id)
        self.assertEqual(len(self.calls), 1)

    def test_revocation_during_exchange_cannot_save_the_late_grant(self):
        self.start()
        def revoke():
            with backend.db() as connection:
                connection.execute("UPDATE auth_sessions SET revoked_at=? WHERE id=?", (self.now.isoformat(), self.admin))
        self.before_exchange = revoke
        self.assert_code("access_required", lambda: self.service.callback(self.callback_query()))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM google_connections").fetchone()[0], 0)

    def test_cancel_during_exchange_preserves_original_connection(self):
        grant_id = self.connect()
        self.request_payload["id"] = str(uuid.uuid4())
        self.start()
        self.before_exchange = lambda: self.service.cancel(self.admin, self.request_payload["id"])
        self.assert_code("request_changed", lambda: self.service.callback(self.callback_query()))
        self.assertEqual(self.service.status(self.admin, self.company)["id"], grant_id)

    def test_cross_user_cannot_read_cancel_disconnect_or_use_another_grant(self):
        grant_id = self.connect()
        other = self.sessions["Accounting"]
        self.assertEqual(self.service.status(other, self.company)["state"], "disconnected")
        self.assert_code("access_required", lambda: self.service.attempt_status(other, self.request_payload["id"]))
        self.assert_code("access_required", lambda: self.service.cancel(other, self.request_payload["id"]))
        self.assert_code("connection_changed", lambda: self.service.disconnect(other, self.company, grant_id))
        self.assert_code("connection_changed", lambda: self.service.access(other, self.company, grant_id, google.FEATURE_SCOPES["mail"]))

    def test_missing_key_corruption_and_copied_ciphertext_fail_without_erasing_data(self):
        grant_id = self.connect()
        with backend.db() as connection:
            row = dict(connection.execute("SELECT * FROM google_connections").fetchone())
        self.service.encryption_key = ""
        self.assert_code("not_configured", lambda: self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]))
        self.service.encryption_key = Fernet.generate_key().decode()
        self.assert_code("storage_unavailable", lambda: self.service.open("grant", row))
        self.service.encryption_key = self.key
        for changes in ({"id": str(uuid.uuid4())}, {"company_id": str(uuid.uuid4())}, {"actor_email": "other@example.invalid"}, {"secrets_ciphertext": row["secrets_ciphertext"][:-8]}):
            self.assert_code("storage_unavailable", lambda: self.service.open("grant", {**row, **changes}))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT secrets_ciphertext FROM google_connections").fetchone()[0], row["secrets_ciphertext"])

    def test_refresh_is_server_only_and_preserves_offline_token_when_not_reissued(self):
        grant_id = self.connect()
        self.now += timedelta(hours=1)
        def refresh(form):
            self.calls.append(form)
            return {"access_token": "fixture-refreshed", "token_type": "Bearer", "expires_in": 3600}
        self.service.transport = refresh
        self.assertEqual(self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]), "fixture-refreshed")
        self.assertEqual(self.calls[-1]["refresh_token"], "fixture-refresh")
        with backend.db() as connection:
            row = connection.execute("SELECT * FROM google_connections").fetchone()
            self.assertEqual(self.service.open("grant", row)["refresh_token"], "fixture-refresh")
        self.assertEqual(self.service.status(self.admin, self.company)["state"], "active")

    def test_simultaneous_refreshes_claim_only_one_provider_request(self):
        grant_id = self.connect()
        self.now += timedelta(hours=1)
        def during_refresh():
            self.assert_code("connection_changed", lambda: self.make_service().access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]))
        self.before_refresh = during_refresh
        self.assertEqual(self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]), "fixture-access")
        self.assertEqual(len(self.calls), 2)

    def test_refresh_failure_retains_locked_credential_and_never_replays(self):
        grant_id = self.connect()
        self.now += timedelta(hours=1)
        self.before_refresh = lambda: (_ for _ in ()).throw(google.ConnectionError("provider_unconfirmed", "fixture", 502))
        self.assert_code("provider_unconfirmed", lambda: self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]))
        self.assertEqual(self.service.status(self.admin, self.company)["state"], "review")
        self.assert_code("connection_changed", lambda: self.make_service().access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]))
        self.assertEqual(len(self.calls), 2)
        with backend.db() as connection:
            self.assertIsNotNone(connection.execute("SELECT secrets_ciphertext FROM google_connections").fetchone()[0])

    def test_disconnect_during_refresh_cannot_restore_credentials(self):
        grant_id = self.connect()
        self.now += timedelta(hours=1)
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at=? WHERE id=?", (self.now.isoformat(), self.admin))
        self.before_refresh = lambda: self.service.disconnect(self.admin, self.company, grant_id)
        self.assert_code("connection_changed", lambda: self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]))
        self.assertEqual(self.service.status(self.admin, self.company)["state"], "disconnected")
        with backend.db() as connection:
            self.assertIsNone(connection.execute("SELECT secrets_ciphertext FROM google_connections").fetchone()[0])

    def test_reconnect_identity_is_immutable_even_after_disconnect(self):
        grant_id = self.connect()
        self.service.disconnect(self.admin, self.company, grant_id)
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET provider='apple',provider_subject='apple-subject' WHERE id=?", (self.admin,))
        self.request_payload["id"] = str(uuid.uuid4())
        self.start()
        self.claim_changes = {"sub": "replacement-google-subject"}
        self.assert_code("account_mismatch", lambda: self.service.callback(self.callback_query()))
        self.assertEqual(self.service.status(self.admin, self.company)["state"], "disconnected")
        self.assertEqual(len(self.calls), 2)  # No project-wide revocation request.

    def test_disconnecting_old_grant_cannot_disconnect_new_connection(self):
        old_id = self.connect()
        self.request_payload["id"] = str(uuid.uuid4())
        new_id = self.connect()
        self.assertNotEqual(old_id, new_id)
        self.assert_code("connection_changed", lambda: self.service.disconnect(self.admin, self.company, old_id))
        self.assertEqual(self.service.status(self.admin, self.company)["id"], new_id)

    def test_audit_failure_rolls_back_grant_and_keeps_attempt_for_review(self):
        self.start()
        def fail(*args, **kwargs):
            raise sqlite3.OperationalError("fixture audit unavailable")
        self.service.audit = fail
        with self.assertRaises(sqlite3.OperationalError):
            self.service.callback(self.callback_query())
        self.assertEqual(self.service.status(self.admin, self.company)["state"], "disconnected")
        self.assertEqual(self.service.attempt_status(self.admin, self.request_payload["id"])["state"], "review")

    def test_backup_restore_preserves_bindings_and_encrypted_credentials(self):
        grant_id = self.connect()
        backup_path = Path(self.directory.name) / "restored.sqlite3"
        with backend.db() as source, sqlite3.connect(backup_path) as destination:
            source.backup(destination)
        def database():
            connection = sqlite3.connect(backup_path)
            connection.row_factory = sqlite3.Row
            return connection
        restored = self.make_service(database)
        self.assertEqual(restored.status(self.admin, self.company)["id"], grant_id)
        self.assertEqual(restored.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]), "fixture-access")

    def test_rate_limit_bounds_fresh_authenticated_authorization_attempts(self):
        for _ in range(30):
            self.request_payload["id"] = str(uuid.uuid4())
            self.start()
            self.service.cancel(self.admin, self.request_payload["id"])
        self.request_payload["id"] = str(uuid.uuid4())
        self.assert_code("rate_limited", self.start)

    def test_configuration_does_not_accept_insecure_or_unexpected_redirects(self):
        for uri in ("http://backend.example.invalid/api/google/oauth/callback", "https://user:pass@backend.example.invalid/api/google/oauth/callback",
                    "https://backend.example.invalid/wrong", "https://backend.example.invalid/api/google/oauth/callback?redirect=evil", "https://backend.example.invalid/api/google/oauth/callback#x"):
            self.service.redirect_uri = uri
            self.assert_code("not_configured", self.start)

    def test_company_change_during_exchange_cannot_adopt_a_grant(self):
        self.start()
        def change():
            with backend.db() as connection:
                connection.execute("UPDATE company_identity SET company_id=?", (str(uuid.uuid4()),))
        self.before_exchange = change
        self.assert_code("company_changed", lambda: self.service.callback(self.callback_query()))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM google_connections").fetchone()[0], 0)

    def test_google_subject_already_bound_to_another_user_is_not_silently_ignored(self):
        self.start()
        with backend.db() as connection:
            connection.execute("INSERT INTO google_account_bindings VALUES (?,?,?)", (self.company, "other@example.invalid", "subject-Admin"))
        self.assert_code("account_mismatch", lambda: self.service.callback(self.callback_query()))
        self.assertEqual(self.service.status(self.admin, self.company)["state"], "disconnected")

    def test_restarted_exchange_remains_locked_and_can_be_explicitly_cancelled(self):
        self.start()
        with backend.db() as connection:
            connection.execute("UPDATE google_oauth_attempts SET state='exchanging'")
        restarted = self.make_service()
        self.assert_code("request_finished", lambda: restarted.callback(self.callback_query()))
        self.assertEqual(restarted.cancel(self.admin, self.request_payload["id"])["state"], "cancelled")
        self.assertEqual(self.calls, [])

    def test_expired_attempt_status_is_not_presented_as_an_active_authorization(self):
        self.start()
        self.now += timedelta(minutes=11)
        self.assertEqual(self.service.attempt_status(self.admin, self.request_payload["id"])["state"], "expired")
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at=? WHERE id=?", (self.now.isoformat(), self.admin))
        self.request_payload["id"] = str(uuid.uuid4())
        self.start()
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM google_oauth_attempts WHERE state='expired' AND secrets_ciphertext IS NULL").fetchone()[0], 1)

    def test_refresh_scope_loss_and_expiry_cannot_authorize_feature_use(self):
        grant_id = self.connect()
        self.now += timedelta(hours=1)
        self.token_changes = {"scope": " ".join(google.IDENTITY_SCOPES)}
        self.assert_code("scope_required", lambda: self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]))
        self.assertEqual(self.service.status(self.admin, self.company)["features"], [])
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at=? WHERE id=?", (self.now.isoformat(), self.admin))
        self.token_changes = {"refresh_token_expires_in": 120}
        self.request_payload["id"] = str(uuid.uuid4())
        grant_id = self.connect()
        self.now += timedelta(minutes=3)
        self.assert_code("connection_expired", lambda: self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]))

    def test_revoked_role_during_refresh_prevents_returning_the_access_token(self):
        grant_id = self.connect()
        self.now += timedelta(hours=1)
        def revoke():
            with backend.db() as connection:
                connection.execute("UPDATE users SET role='Standard' WHERE email='admin@example.invalid'")
        self.before_refresh = revoke
        self.assert_code("access_required", lambda: self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["mail"]))
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT state FROM google_connections").fetchone()[0], "review")

    def test_reconnect_while_refreshing_does_not_overwrite_the_new_grant(self):
        old_id = self.connect()
        self.now += timedelta(hours=1)
        with backend.db() as connection:
            connection.execute("UPDATE auth_sessions SET created_at=? WHERE id=?", (self.now.isoformat(), self.admin))
        new_grants = []
        def reconnect():
            self.request_payload["id"] = str(uuid.uuid4())
            new_grants.append(self.connect())
        self.before_refresh = reconnect
        self.assert_code("connection_changed", lambda: self.service.access(self.admin, self.company, old_id, google.FEATURE_SCOPES["mail"]))
        self.assertEqual(self.service.status(self.admin, self.company)["id"], new_grants[0])
        self.assertEqual(self.service.status(self.admin, self.company)["state"], "active")

    def test_corrupted_plaintext_scope_index_cannot_expand_access(self):
        grant_id = self.connect()
        with backend.db() as connection:
            scopes = google.IDENTITY_SCOPES | google.FEATURE_SCOPES["mail"] | google.FEATURE_SCOPES["drive"]
            connection.execute("UPDATE google_connections SET scopes_json=?", (json.dumps(sorted(scopes)),))
        self.assert_code("storage_unavailable", lambda: self.service.access(self.admin, self.company, grant_id, google.FEATURE_SCOPES["drive"]))

    def test_actual_http_contract_is_session_only_and_callback_is_private_safe_html(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        def request(route, payload=None, token=None):
            headers = {"Content-Type": "application/json"}
            if token:
                headers["Authorization"] = "Bearer " + token
            req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}" + route, headers=headers,
                data=payload if isinstance(payload, bytes) else json.dumps(payload).encode() if payload is not None else None)
            try:
                response = urllib.request.build_opener(google.NoRedirect).open(req, timeout=5)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                return response.status, dict(response.headers), response.read().decode()
        try:
            with mock.patch.object(backend.GunnAireBackendHandler, "google_connection_service", return_value=self.service), mock.patch("builtins.print") as logged:
                route = "/api/google/connection?companyID=" + self.company
                self.assertEqual(request(route)[0], 401)
                with mock.patch.multiple(backend, AUTH_MODE="api-token", API_TOKEN="fixture-legacy"):
                    self.assertEqual(request(route, token="fixture-legacy")[0], 403)
                for bad in (b'{"id":"one","id":"two"}', b'{"features":NaN}', b'{"features":Infinity}'):
                    self.assertEqual(request("/api/google/authorizations", bad, self.tokens["Admin"])[0], 400)
                code, headers, body = request("/api/google/authorizations", self.request_payload, self.tokens["Admin"])
                self.assertEqual(code, 200)
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.query = urllib.parse.parse_qs(urllib.parse.urlsplit(json.loads(body)["authorizationURL"]).query)
                code, headers, body = request(google.CALLBACK_PATH + "?" + self.callback_query())
                self.assertEqual(code, 303)
                self.assertEqual(headers["Location"], "gunnaireops://oauth/google/connection?attemptID=" + self.request_payload["id"])
                self.assertIn("connection saved", body)
                self.assertEqual(headers["Referrer-Policy"], "no-referrer")
                self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
                self.assertNotIn("fixture-authorization-code", str(logged.call_args_list))
                self.assertNotIn(self.query["state"][0], str(logged.call_args_list))
                self.assertNotIn("@", body)
                code, headers, _ = request(google.CALLBACK_PATH + "?state=invalid&code=private")
                self.assertEqual(code, 400)
                self.assertNotIn("Location", headers)
                code, _, body = request(route, token=self.tokens["Admin"])
                self.assertEqual(code, 200)
                self.assertNotIn("token", body)
                self.assertEqual(json.loads(body)["state"], "active")
                self.assertEqual(request("/api/google/token", token=self.tokens["Admin"])[0], 404)
                code, _, body = request("/api/google/connection/disconnect", {"companyID": self.company, "grantID": json.loads(body)["id"]}, self.tokens["Admin"])
                self.assertEqual(code, 200)
                self.assertEqual(json.loads(body)["state"], "disconnected")
        finally:
            server.shutdown()
            server.server_close()
            worker.join(5)

    def test_status_and_attempt_metadata_are_scoped_and_discover_original_pending(self):
        empty = self.service.status(self.admin, self.company)
        self.assertEqual(empty["companyID"], self.company)
        self.assertEqual(empty["actorEmail"], "admin@example.invalid")
        self.assertIsNone(empty["pendingAttempt"])
        self.start()
        result = self.service.status(self.admin, self.company)
        attempt = result["pendingAttempt"]
        self.assertEqual(attempt, self.service.attempt_status(self.admin, self.request_payload["id"]))
        self.assertEqual(attempt["companyID"], self.company)
        self.assertEqual(attempt["actorEmail"], "admin@example.invalid")
        self.assertEqual(attempt["features"], ["mail"])
        self.assertIsNone(self.service.status(self.sessions["Accounting"], self.company)["pendingAttempt"])
        self.assertNotIn("authorizationURL", json.dumps(result))
        self.assertNotIn(self.query["state"][0], json.dumps(result))

    def test_cancel_before_delayed_prepare_creates_permanent_original_id_tombstone(self):
        payload = {"companyID": self.company, "features": ["mail"]}
        result = self.service.cancel(self.admin, self.request_payload["id"], payload)
        self.assertEqual(result["state"], "cancelled")
        self.assertEqual(self.service.cancel(self.admin, self.request_payload["id"], payload), result)
        self.assert_code("request_finished", self.start)
        with backend.db() as connection:
            self.assertIsNone(connection.execute("SELECT secrets_ciphertext FROM google_oauth_attempts").fetchone()[0])
        self.assertEqual(self.calls, [])

    def test_cancel_payload_cannot_switch_scope_features_or_original_owner(self):
        self.start()
        for payload in ({"companyID": str(uuid.uuid4()), "features": ["mail"]}, {"companyID": self.company, "features": ["drive"]}):
            self.assert_code("request_changed", lambda: self.service.cancel(self.admin, self.request_payload["id"], payload))
        payload = {"companyID": self.company, "features": ["mail"]}
        self.assert_code("access_required", lambda: self.service.cancel(self.sessions["Accounting"], self.request_payload["id"], payload))
        for features in ([], ["all"], ["mail", "mail"], [["mail"]], True):
            self.assert_code("invalid_request", lambda: self.service.cancel(self.admin, self.request_payload["id"], {**payload, "features": features}))
        self.assertEqual(self.service.attempt_status(self.admin, self.request_payload["id"])["state"], "pending")

    def test_cancel_tombstones_are_rate_bounded_without_blocking_existing_cancellation(self):
        self.start()
        payload = {"companyID": self.company, "features": ["mail"]}
        for _ in range(29):
            self.service.cancel(self.admin, str(uuid.uuid4()), payload)
        self.assert_code("rate_limited", lambda: self.service.cancel(self.admin, str(uuid.uuid4()), payload))
        self.assertEqual(self.service.cancel(self.admin, self.request_payload["id"], payload)["state"], "cancelled")


class GoogleTransportTests(unittest.TestCase):
    def test_transport_is_fixed_origin_bounded_and_does_not_follow_redirects(self):
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b'{"access_token":"fixture"}'
        opener = mock.Mock()
        opener.open.return_value = response
        with mock.patch.object(urllib.request, "build_opener", return_value=opener) as factory:
            self.assertEqual(google.token_transport({"code": "private-fixture"}), {"access_token": "fixture"})
            request = opener.open.call_args.args[0]
            self.assertEqual(request.full_url, "https://oauth2.googleapis.com/token")
            self.assertEqual(request.method, "POST")
            self.assertNotIn("private-fixture", request.full_url)
            self.assertIs(factory.call_args.args[0], google.NoRedirect)
            self.assertIsNone(factory.call_args.args[0]().redirect_request(None, None, 302, None, None, "https://attacker.invalid"))
            response.read.return_value = b"x" * (64 * 1024 + 1)
            with self.assertRaises(google.ConnectionError):
                google.token_transport({"code": "private-fixture"})
            response.read.return_value = b'{"access_token":"first","access_token":"second"}'
            with self.assertRaises(google.ConnectionError):
                google.token_transport({"code": "private-fixture"})
            opener.open.side_effect = urllib.error.HTTPError(google.TOKEN_URL, 400, "private-fixture", {}, io.BytesIO(b"secret-provider-body"))
            with self.assertRaises(google.ConnectionError) as caught:
                google.token_transport({"code": "private-fixture"})
            self.assertNotIn("private-fixture", str(caught.exception))
            self.assertNotIn("secret-provider-body", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
