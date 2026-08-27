from __future__ import annotations

import base64
import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
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
                    "sub": "apple-user-verified-001",
                    "email": email,
                    "email_verified": "true",
                },
                separators=(",", ":"),
            ).encode()
        )
        signing_input = f"{header}.{claims}".encode("ascii")
        signature = self.private_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
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
        self.assertIsNotNone(session)
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


if __name__ == "__main__":
    unittest.main()
