from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from Backend import gunnaire_backend as backend


class GoogleAuthenticationTests(unittest.TestCase):
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
            GOOGLE_CLIENT_ID="google-client.apps.googleusercontent.com",
            GOOGLE_ALLOWED_DOMAIN="gunnaire.com",
            APP_SESSION_DAYS=30,
        )
        self.configuration.start()
        self.google_verifier = mock.Mock(side_effect=self.verify_identity_token)
        self.google_modules = mock.patch.multiple(
            backend,
            google_id_token=SimpleNamespace(verify_oauth2_token=self.google_verifier),
            google_requests=SimpleNamespace(Request=lambda: object()),
            create=True,
        )
        self.google_modules.start()
        backend.initialize_database()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.google_modules.stop()
        self.configuration.stop()
        self.temporary_directory.cleanup()

    @staticmethod
    def verify_identity_token(identity_token: str, _request: object, audience: str) -> dict[str, object]:
        if audience != "google-client.apps.googleusercontent.com" or identity_token.startswith("invalid-token"):
            raise ValueError("invalid token")
        claims: dict[str, object] = {
            "sub": "google-user-verified-001",
            "email": "eric.gunn@gunnaire.com",
            "email_verified": True,
            "hd": "gunnaire.com",
        }
        if identity_token.startswith("wrong-domain-token"):
            claims["hd"] = "example.com"
        elif identity_token.startswith("unverified-email-token"):
            claims["email_verified"] = False
        elif identity_token.startswith("unapproved-user-token"):
            claims["email"] = "unapproved@gunnaire.com"
            claims["sub"] = "google-user-unapproved"
        return claims

    def post_google_login(self, identity_token: str) -> tuple[int, dict[str, object]]:
        request = urllib.request.Request(
            f"{self.base_url}/api/auth/google",
            data=json.dumps({"identityToken": identity_token}).encode("utf-8"),
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

    def test_verified_google_identity_creates_hashed_revocable_role_session(self) -> None:
        status, payload = self.post_google_login("verified-google-identity-token-" + "x" * 100)

        self.assertEqual(status, 200)
        session_token = str(payload["sessionToken"])
        self.assertGreaterEqual(len(session_token), 32)
        self.assertEqual(payload["providerSubject"], "google-user-verified-001")
        self.assertEqual(payload["user"]["role"], "Admin")
        with backend.db() as connection:
            session = connection.execute("SELECT * FROM auth_sessions").fetchone()
        self.assertIsNotNone(session)
        self.assertEqual(session["provider"], "google")
        self.assertEqual(session["provider_subject"], "google-user-verified-001")
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

    def test_google_exchange_rejects_invalid_domain_unverified_and_unapproved_accounts(self) -> None:
        for prefix in ("invalid-token", "wrong-domain-token", "unverified-email-token"):
            identity_token = prefix + "-" + "x" * 100
            with self.subTest(identity_token=identity_token):
                status, payload = self.post_google_login(identity_token)
                self.assertEqual(status, 401)
                self.assertEqual(payload["error"], "Google authentication failed")

        status, payload = self.post_google_login("unapproved-user-token-" + "x" * 100)
        self.assertEqual(status, 403)
        self.assertEqual(payload["error"], "Business account access is not approved")

    def test_deactivated_google_user_invalidates_an_existing_application_session(self) -> None:
        status, payload = self.post_google_login("verified-google-identity-token-" + "x" * 100)
        self.assertEqual(status, 200)
        with backend.db() as connection:
            connection.execute(
                "UPDATE users SET is_active = 0 WHERE email = ?",
                ("eric.gunn@gunnaire.com",),
            )
        self.assertEqual(self.get_session(str(payload["sessionToken"]))[0], 401)


if __name__ == "__main__":
    unittest.main()
