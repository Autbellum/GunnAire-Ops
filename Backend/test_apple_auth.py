from __future__ import annotations

import base64
import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from Backend import gunnaire_backend as backend


def base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


class AppleAuthenticationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.configuration = mock.patch.multiple(
            backend,
            DATA_ROOT=root,
            DB_PATH=root / "gunnaire_backend.sqlite3",
            STORAGE_ROOT=root / "storage",
            BACKUP_STATUS_PATH=root / "backup_status.json",
            AUTH_MODE="google-id-token",
            APPLE_CLIENT_ID="com.gunnaire.businesssuite",
            APP_SESSION_DAYS=30,
        )
        self.configuration.start()
        self.private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.apple_key = mock.patch.object(
            backend,
            "apple_public_key",
            return_value=self.private_key.public_key(),
        )
        self.apple_key.start()
        backend.initialize_database()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.apple_key.stop()
        self.configuration.stop()
        self.temporary_directory.cleanup()

    def identity_token(
        self,
        *,
        email: str = "eric.gunn@gunnaire.com",
        nonce: str = "verified-apple-request-nonce-12345",
        audience: str = "com.gunnaire.businesssuite",
        expiration_offset: int = 300,
        subject: str = "apple-user-verified-001",
    ) -> str:
        now = int(time.time())
        header = base64url(json.dumps({"alg": "RS256", "kid": "TESTAPPLE1"}, separators=(",", ":")).encode())
        claims = base64url(
            json.dumps(
                {
                    "iss": "https://appleid.apple.com",
                    "aud": audience,
                    "exp": now + expiration_offset,
                    "iat": now,
                    "nonce": nonce,
                    "sub": subject,
                    "email": email,
                    "email_verified": "true",
                },
                separators=(",", ":"),
            ).encode()
        )
        signing_input = f"{header}.{claims}".encode("ascii")
        signature = self.private_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
        return f"{header}.{claims}.{base64url(signature)}"

    def account_notification(
        self,
        *,
        event_type: str = "consent-revoked",
        subject: str = "apple-user-verified-001",
        audience: str = "com.gunnaire.businesssuite",
        issuer: str = "https://appleid.apple.com",
        issued_at: int | None = None,
        event_time: int | None = None,
        event_id: str | None = None,
        email: str = "private-relay@privaterelay.appleid.com",
        signing_key: rsa.RSAPrivateKey | None = None,
    ) -> str:
        now = int(time.time())
        events: dict[str, object] = {
            "type": event_type,
            "sub": subject,
            "event_time": now if event_time is None else event_time,
        }
        if event_type in {"email-enabled", "email-disabled"}:
            events.update({"email": email, "is_private_email": "true"})
        header = base64url(
            json.dumps({"alg": "RS256", "kid": "TESTAPPLE1"}, separators=(",", ":")).encode()
        )
        claims = base64url(
            json.dumps(
                {
                    "iss": issuer,
                    "aud": audience,
                    "iat": now if issued_at is None else issued_at,
                    "jti": event_id or str(uuid.uuid4()),
                    "events": events,
                },
                separators=(",", ":"),
            ).encode()
        )
        signing_input = f"{header}.{claims}".encode("ascii")
        signature = (signing_key or self.private_key).sign(
            signing_input,
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
        return f"{header}.{claims}.{base64url(signature)}"

    def post_apple_login(self, identity_token: str, nonce: str) -> tuple[int, dict[str, object]]:
        request = urllib.request.Request(
            f"{self.base_url}/api/auth/apple",
            data=json.dumps({"identityToken": identity_token, "nonce": nonce}).encode("utf-8"),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read().decode("utf-8"))

    def post_account_notification(
        self,
        signed_payload: str | None,
        *,
        content_type: str = "application/json",
        extra_body: dict[str, object] | None = None,
    ) -> tuple[int, dict[str, object]]:
        body: dict[str, object] = {} if signed_payload is None else {"payload": signed_payload}
        if extra_body:
            body.update(extra_body)
        request = urllib.request.Request(
            f"{self.base_url}/api/auth/apple/notifications",
            data=json.dumps(body).encode("utf-8"),
            method="POST",
            headers={"Content-Type": content_type},
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read().decode("utf-8"))

    def get_session(self, token: str) -> tuple[int, dict[str, object]]:
        request = urllib.request.Request(
            f"{self.base_url}/api/session",
            headers={"Authorization": f"Bearer {token}"},
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read().decode("utf-8"))

    def test_verified_apple_identity_creates_hashed_revocable_role_session(self) -> None:
        nonce = "verified-apple-request-nonce-12345"
        identity_token = self.identity_token(nonce=nonce)

        status, payload = self.post_apple_login(identity_token, nonce)

        self.assertEqual(status, 200)
        session_token = str(payload["sessionToken"])
        self.assertGreaterEqual(len(session_token), 32)
        self.assertEqual(payload["providerSubject"], "apple-user-verified-001")
        self.assertEqual(payload["user"]["role"], "Admin")
        with backend.db() as connection:
            session = connection.execute("SELECT * FROM auth_sessions").fetchone()
            identity = connection.execute(
                "SELECT * FROM apple_identities WHERE provider_subject = ?",
                ("apple-user-verified-001",),
            ).fetchone()
        self.assertIsNotNone(session)
        self.assertIsNotNone(identity)
        self.assertEqual(identity["email"], "eric.gunn@gunnaire.com")
        self.assertEqual(identity["credential_state"], "authorized")
        self.assertNotEqual(session["token_hash"], session_token)
        self.assertEqual(session["token_hash"], backend.app_session_token_hash(session_token))

        session_status, session_payload = self.get_session(session_token)
        self.assertEqual(session_status, 200)
        self.assertEqual(session_payload["user"]["email"], "eric.gunn@gunnaire.com")

        logout_request = urllib.request.Request(
            f"{self.base_url}/api/auth/logout",
            data=b"{}",
            method="POST",
            headers={"Authorization": f"Bearer {session_token}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(logout_request, timeout=5) as response:
            self.assertEqual(response.status, 200)
        self.assertEqual(self.get_session(session_token)[0], 401)

    def test_apple_login_rejects_nonce_audience_expiry_and_signature_failures(self) -> None:
        nonce = "verified-apple-request-nonce-12345"
        invalid_tokens = [
            (self.identity_token(nonce=nonce), "different-apple-request-nonce-123"),
            (self.identity_token(nonce=nonce, audience="wrong.client"), nonce),
            (self.identity_token(nonce=nonce, expiration_offset=-1), nonce),
        ]
        tampered_segments = self.identity_token(nonce=nonce).split(".")
        tampered_signature = tampered_segments[2]
        tampered_segments[2] = ("A" if tampered_signature[0] != "A" else "B") + tampered_signature[1:]
        invalid_tokens.append((".".join(tampered_segments), nonce))

        for identity_token, submitted_nonce in invalid_tokens:
            with self.subTest(token=identity_token[-12:], nonce=submitted_nonce):
                status, payload = self.post_apple_login(identity_token, submitted_nonce)
                self.assertEqual(status, 401)
                self.assertEqual(payload["error"], "Apple authentication failed")

    def test_valid_but_unapproved_or_deactivated_apple_identity_is_denied(self) -> None:
        nonce = "verified-apple-request-nonce-12345"
        status, payload = self.post_apple_login(
            self.identity_token(email="private-relay@privaterelay.appleid.com", nonce=nonce),
            nonce,
        )
        self.assertEqual(status, 403)
        self.assertEqual(payload["error"], "Business account access is not approved")

        approved_status, approved = self.post_apple_login(self.identity_token(nonce=nonce), nonce)
        self.assertEqual(approved_status, 200)
        with backend.db() as connection:
            connection.execute(
                "UPDATE users SET is_active = 0 WHERE email = ?",
                ("eric.gunn@gunnaire.com",),
            )
        self.assertEqual(self.get_session(str(approved["sessionToken"]))[0], 401)

    def test_consent_revocation_revokes_sessions_and_deactivates_push_devices(self) -> None:
        nonce = "verified-apple-request-nonce-12345"
        login_status, login = self.post_apple_login(self.identity_token(nonce=nonce), nonce)
        self.assertEqual(login_status, 200)
        session_token = str(login["sessionToken"])
        with backend.db() as connection:
            session = connection.execute("SELECT * FROM auth_sessions").fetchone()
            connection.execute(
                """
                INSERT INTO push_devices(
                    id, installation_id, token_ciphertext, token_fingerprint, email,
                    auth_session_id, platform, environment, bundle_id, app_version,
                    app_build, created_at, updated_at, deactivated_at
                ) VALUES (?, ?, ?, ?, ?, ?, 'ios', 'sandbox', ?, '1.0', '1', ?, ?, NULL)
                """,
                (
                    "push-device-apple-1",
                    "installation-apple-1",
                    "encrypted-token-placeholder",
                    "token-fingerprint-apple-1",
                    "eric.gunn@gunnaire.com",
                    session["id"],
                    "com.gunnaire.businesssuite",
                    backend.utc_now(),
                    backend.utc_now(),
                ),
            )

        event_id = str(uuid.uuid4())
        status, payload = self.post_account_notification(
            self.account_notification(event_type="consent-revoked", event_id=event_id)
        )

        self.assertEqual(status, 200)
        self.assertEqual(payload, {"accepted": True, "idempotentReplay": False})
        self.assertEqual(self.get_session(session_token)[0], 401)
        with backend.db() as connection:
            session = connection.execute("SELECT * FROM auth_sessions").fetchone()
            identity = connection.execute("SELECT * FROM apple_identities").fetchone()
            device = connection.execute("SELECT * FROM push_devices").fetchone()
            event = connection.execute(
                "SELECT * FROM apple_account_events WHERE jti = ?",
                (event_id,),
            ).fetchone()
            audit = connection.execute(
                "SELECT * FROM audit_events WHERE action = 'consent-revoked'"
            ).fetchone()
        self.assertIsNotNone(session["revoked_at"])
        self.assertEqual(identity["credential_state"], "consent-revoked")
        self.assertIsNotNone(device["deactivated_at"])
        self.assertEqual(event["sessions_revoked"], 1)
        self.assertEqual(event["devices_deactivated"], 1)
        self.assertEqual(event["subject_hash"], backend.hashlib.sha256(b"apple-user-verified-001").hexdigest())
        self.assertEqual(event["matched_email"], "eric.gunn@gunnaire.com")
        self.assertNotIn("private-relay", "|".join(str(value) for value in event))
        self.assertIsNotNone(audit)
        self.assertNotEqual(audit["subject_id"], "apple-user-verified-001")

    def test_email_forwarding_events_are_idempotent_and_do_not_revoke_session(self) -> None:
        nonce = "verified-apple-request-nonce-12345"
        login_status, login = self.post_apple_login(self.identity_token(nonce=nonce), nonce)
        self.assertEqual(login_status, 200)
        session_token = str(login["sessionToken"])
        event_id = str(uuid.uuid4())
        notification = self.account_notification(event_type="email-disabled", event_id=event_id)

        first_status, first = self.post_account_notification(notification)
        replay_status, replay = self.post_account_notification(notification)

        self.assertEqual(first_status, 200)
        self.assertEqual(first, {"accepted": True, "idempotentReplay": False})
        self.assertEqual(replay_status, 200)
        self.assertEqual(replay, {"accepted": True, "idempotentReplay": True})
        self.assertEqual(self.get_session(session_token)[0], 200)
        with backend.db() as connection:
            identity = connection.execute("SELECT * FROM apple_identities").fetchone()
            event_count = connection.execute(
                "SELECT COUNT(*) AS count FROM apple_account_events WHERE jti = ?",
                (event_id,),
            ).fetchone()["count"]
            audit_count = connection.execute(
                "SELECT COUNT(*) AS count FROM audit_events WHERE action = 'email-disabled'"
            ).fetchone()["count"]
        self.assertEqual(identity["relay_enabled"], 0)
        self.assertEqual(event_count, 1)
        self.assertEqual(audit_count, 1)

        enabled_status, enabled = self.post_account_notification(
            self.account_notification(event_type="email-enabled")
        )
        self.assertEqual(enabled_status, 200)
        self.assertFalse(bool(enabled["idempotentReplay"]))
        with backend.db() as connection:
            identity = connection.execute("SELECT * FROM apple_identities").fetchone()
        self.assertEqual(identity["relay_enabled"], 1)
        self.assertEqual(self.get_session(session_token)[0], 200)

    def test_account_deletion_revokes_the_matching_apple_session(self) -> None:
        nonce = "verified-apple-request-nonce-12345"
        login_status, login = self.post_apple_login(self.identity_token(nonce=nonce), nonce)
        self.assertEqual(login_status, 200)

        status, payload = self.post_account_notification(
            self.account_notification(event_type="account-deleted")
        )

        self.assertEqual(status, 200)
        self.assertEqual(payload, {"accepted": True, "idempotentReplay": False})
        self.assertEqual(self.get_session(str(login["sessionToken"]))[0], 401)
        with backend.db() as connection:
            identity = connection.execute("SELECT * FROM apple_identities").fetchone()
            event = connection.execute("SELECT * FROM apple_account_events").fetchone()
        self.assertEqual(identity["credential_state"], "account-deleted")
        self.assertEqual(event["event_type"], "account-deleted")
        self.assertEqual(event["sessions_revoked"], 1)

    def test_notification_rejects_invalid_body_signature_claims_and_event(self) -> None:
        now = int(time.time())
        other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        invalid_notifications = [
            ("wrong-audience", self.account_notification(audience="wrong.client")),
            ("wrong-issuer", self.account_notification(issuer="https://example.invalid")),
            ("future-issued-at", self.account_notification(issued_at=now + 3600)),
            ("future-event-time", self.account_notification(event_time=now + 3600)),
            ("unsupported-event", self.account_notification(event_type="unexpected-event")),
            ("wrong-signing-key", self.account_notification(signing_key=other_key)),
        ]
        for case, notification in invalid_notifications:
            with self.subTest(case=case):
                status, payload = self.post_account_notification(notification)
                self.assertEqual(status, 401)
                self.assertEqual(payload["error"], "Apple account notification verification failed")

        for signed_payload, content_type, extra_body in [
            (None, "application/json", None),
            (self.account_notification(), "text/plain", None),
            (self.account_notification(), "application/json", {"unexpected": True}),
        ]:
            with self.subTest(content_type=content_type, extra_body=extra_body):
                status, payload = self.post_account_notification(
                    signed_payload,
                    content_type=content_type,
                    extra_body=extra_body,
                )
                self.assertEqual(status, 400)
                self.assertEqual(payload["error"], "Invalid Apple account notification")

    def test_valid_unknown_identity_event_is_acknowledged_without_creating_identity(self) -> None:
        event_id = str(uuid.uuid4())
        status, payload = self.post_account_notification(
            self.account_notification(subject="unknown-apple-user", event_id=event_id)
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload, {"accepted": True, "idempotentReplay": False})
        with backend.db() as connection:
            identity_count = connection.execute(
                "SELECT COUNT(*) AS count FROM apple_identities"
            ).fetchone()["count"]
            event = connection.execute(
                "SELECT * FROM apple_account_events WHERE jti = ?",
                (event_id,),
            ).fetchone()
        self.assertEqual(identity_count, 0)
        self.assertIsNone(event["matched_email"])

    def test_apple_subject_cannot_be_relinked_to_another_business_user(self) -> None:
        nonce = "verified-apple-request-nonce-12345"
        first_status, _ = self.post_apple_login(self.identity_token(nonce=nonce), nonce)
        self.assertEqual(first_status, 200)
        with backend.db() as connection:
            now = backend.utc_now()
            connection.execute(
                "INSERT INTO users(email, role, is_active, created_at, updated_at) VALUES (?, 'Admin', 1, ?, ?)",
                ("other@gunnaire.com", now, now),
            )
        second_status, second = self.post_apple_login(
            self.identity_token(email="other@gunnaire.com", nonce=nonce),
            nonce,
        )
        self.assertEqual(second_status, 403)
        self.assertEqual(second["error"], "Apple identity is already linked to another business account")

    def test_stale_revocation_after_reauthentication_does_not_revoke_fresh_session(self) -> None:
        nonce = "verified-apple-request-nonce-12345"
        old_event_time = int(time.time()) - 60
        first_status, _ = self.post_apple_login(self.identity_token(nonce=nonce), nonce)
        self.assertEqual(first_status, 200)
        fresh_status, fresh = self.post_apple_login(self.identity_token(nonce=nonce), nonce)
        self.assertEqual(fresh_status, 200)

        status, payload = self.post_account_notification(
            self.account_notification(event_type="consent-revoked", event_time=old_event_time)
        )

        self.assertEqual(status, 200)
        self.assertEqual(payload, {"accepted": True, "idempotentReplay": False})
        self.assertEqual(self.get_session(str(fresh["sessionToken"]))[0], 200)
        with backend.db() as connection:
            identity = connection.execute("SELECT * FROM apple_identities").fetchone()
            event = connection.execute("SELECT * FROM apple_account_events").fetchone()
        self.assertEqual(identity["credential_state"], "authorized")
        self.assertEqual(event["sessions_revoked"], 0)


if __name__ == "__main__":
    unittest.main()
