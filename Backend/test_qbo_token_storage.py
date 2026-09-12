"""Regression coverage for the confidential QuickBooks OAuth token boundary."""

from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet


BACKEND_PATH = Path(__file__).with_name("gunnaire_backend.py")


def load_backend(database_path: Path, encryption_key: str):
    """Load an isolated backend module with no production environment state."""
    original_environment = os.environ.copy()
    os.environ["GUNNAIRE_BACKEND_DB"] = str(database_path)
    os.environ["GUNNAIRE_QBO_TOKEN_ENCRYPTION_KEY"] = encryption_key
    try:
        spec = importlib.util.spec_from_file_location("gunnaire_backend_qbo_test", BACKEND_PATH)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        os.environ.clear()
        os.environ.update(original_environment)


class QuickBooksTokenStorageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.backend = load_backend(root / "backend.sqlite3", Fernet.generate_key().decode("utf-8"))

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_client_token_response_omits_refresh_token(self) -> None:
        response = self.backend.qbo_client_token_response(
            {"access_token": "short-lived-access", "refresh_token": "long-lived-refresh", "expires_in": 3600}
        )

        self.assertEqual(response, {"accessToken": "short-lived-access", "expiresIn": 3600})
        self.assertNotIn("refreshToken", response)

    def test_refresh_token_is_encrypted_and_connection_schema_is_created(self) -> None:
        ciphertext = self.backend.encrypt_qbo_refresh_token("long-lived-refresh")

        self.assertNotEqual(ciphertext, "long-lived-refresh")
        self.assertEqual(self.backend.decrypt_qbo_refresh_token(ciphertext), "long-lived-refresh")
        self.backend.initialize_database()
        with self.backend.db() as connection:
            columns = {row["name"] for row in connection.execute("PRAGMA table_info(qbo_connections)")}
        self.assertTrue(
            {"realm_id", "refresh_token_ciphertext", "environment", "client_id_fingerprint", "authorized_at", "updated_at"}
            <= columns
        )

    def test_missing_encryption_key_fails_closed(self) -> None:
        self.backend.QBO_TOKEN_ENCRYPTION_KEY = ""

        self.assertFalse(self.backend.qbo_token_storage_is_configured())
        with self.assertRaises(RuntimeError):
            self.backend.encrypt_qbo_refresh_token("long-lived-refresh")

    def test_connection_context_must_match_saved_realm_and_environment(self) -> None:
        self.backend.initialize_database()
        with self.backend.db() as connection:
            connection.execute(
                """
                INSERT INTO qbo_connections(
                    id, realm_id, refresh_token_ciphertext, environment,
                    client_id_fingerprint, authorized_at, updated_at
                ) VALUES (1, '12345', 'ciphertext', 'production', 'fingerprint', 'now', 'now')
                """
            )
            row = connection.execute("SELECT * FROM qbo_connections WHERE id = 1").fetchone()

        self.assertTrue(self.backend.qbo_connection_matches(row, "12345", "production"))
        self.assertFalse(self.backend.qbo_connection_matches(row, "other-company", "production"))
        self.assertFalse(self.backend.qbo_connection_matches(row, "12345", "sandbox"))



    def seed_oauth_connection(self, **overrides):
        self.backend.initialize_database()
        values = {
            "realm_id": "fixture-realm", "environment": "sandbox",
            "client_id_fingerprint": "fixture-client", "authorized_at": "fixture-grant",
            "updated_at": "fixture-updated",
            "refresh_token_ciphertext": self.backend.encrypt_qbo_refresh_token("fixture-refresh"),
        }
        values.update(overrides)
        with self.backend.db() as connection:
            connection.execute(
                """INSERT OR REPLACE INTO qbo_connections
                   (id, realm_id, environment, client_id_fingerprint, authorized_at, updated_at,
                    refresh_token_ciphertext) VALUES (1, ?, ?, ?, ?, ?, ?)""",
                tuple(values[key] for key in (
                    "realm_id", "environment", "client_id_fingerprint", "authorized_at",
                    "updated_at", "refresh_token_ciphertext",
                )),
            )
        return self.read_oauth_connection()

    def read_oauth_connection(self):
        with self.backend.db() as connection:
            row = connection.execute("SELECT * FROM qbo_connections WHERE id = 1").fetchone()
        return dict(row) if row else None

    def oauth_handler(self):
        # Test the actual handler's persistence/network boundary, not route auth.
        # All OAuth transports are replaced and no real HTTP server is started.
        handler = object.__new__(self.backend.GunnAireBackendHandler)
        responses = []
        handler.read_json = lambda: {"realmID": "fixture-realm", "environment": "sandbox"}
        handler.principal = lambda: {"email": "fixture-admin@example.invalid", "role": "Admin"}
        handler.write_json = lambda payload, status=200, **kwargs: responses.append((status, payload))
        return handler, responses

    def oauth_audit_count(self):
        with self.backend.db() as connection:
            return connection.execute(
                "SELECT COUNT(*) FROM audit_events WHERE subject_type = 'quickbooks'"
            ).fetchone()[0]

    def test_actual_refresh_persists_rotation_and_audit_before_returning_only_access_token(self):
        original = self.seed_oauth_connection()
        handler, responses = self.oauth_handler()
        with mock.patch.object(self.backend, "qbo_request", return_value=(200, {
            "access_token": "fixture-access", "refresh_token": "fixture-rotated", "expires_in": 3600,
        })) as transport:
            handler.refresh_qbo_access_token()
        transport.assert_called_once()
        self.assertEqual(responses, [(200, {"accessToken": "fixture-access", "expiresIn": 3600})])
        current = self.read_oauth_connection()
        self.assertNotEqual(current["refresh_token_ciphertext"], original["refresh_token_ciphertext"])
        self.assertEqual(self.backend.decrypt_qbo_refresh_token(current["refresh_token_ciphertext"]), "fixture-rotated")
        self.assertEqual(current["authorized_at"], original["authorized_at"])
        self.assertEqual(self.oauth_audit_count(), 1)

    def test_actual_refresh_rejects_every_replaced_or_removed_grant_without_returning_old_access(self):
        for changed_field in (
            "refresh_token_ciphertext", "realm_id", "environment",
            "client_id_fingerprint", "authorized_at", "removed",
        ):
            with self.subTest(changed_field=changed_field):
                original = self.seed_oauth_connection()
                handler, responses = self.oauth_handler()
                replacement = None

                def finish_old_refresh(*args):
                    nonlocal replacement
                    with self.backend.db() as connection:
                        if changed_field == "removed":
                            connection.execute("DELETE FROM qbo_connections WHERE id = 1")
                        else:
                            # Field names come from this fixed test list only.
                            connection.execute(
                                f"UPDATE qbo_connections SET {changed_field} = ? WHERE id = 1",
                                ("fixture-replacement",),
                            )
                    replacement = self.read_oauth_connection()
                    return 200, {
                        "access_token": "must-not-return-old-access",
                        "refresh_token": "must-not-save-old-refresh", "expires_in": 3600,
                    }

                with mock.patch.object(self.backend, "qbo_request", side_effect=finish_old_refresh):
                    handler.refresh_qbo_access_token()
                self.assertEqual(responses[0][0], 409)
                self.assertNotIn("accessToken", responses[0][1])
                self.assertEqual(self.read_oauth_connection(), replacement)
                self.assertNotEqual(self.read_oauth_connection(), original)
                self.assertEqual(self.oauth_audit_count(), 0)

    def test_actual_revoke_only_deletes_and_audits_the_original_grant(self):
        self.seed_oauth_connection()
        handler, responses = self.oauth_handler()
        with mock.patch.object(self.backend, "qbo_request", return_value=(200, {})):
            handler.revoke_qbo_token()
        self.assertEqual(responses, [(200, {"revoked": True})])
        self.assertIsNone(self.read_oauth_connection())
        self.assertEqual(self.oauth_audit_count(), 1)

    def test_late_revoke_preserves_reconnection_and_does_not_claim_it_is_revoked(self):
        self.seed_oauth_connection()
        handler, responses = self.oauth_handler()
        replacement = None

        def finish_old_revoke(*args):
            nonlocal replacement
            replacement = self.seed_oauth_connection(
                refresh_token_ciphertext=self.backend.encrypt_qbo_refresh_token("fixture-new-grant")
            )
            return 200, {}

        with mock.patch.object(self.backend, "qbo_request", side_effect=finish_old_revoke):
            handler.revoke_qbo_token()
        self.assertEqual(responses[0][0], 409)
        self.assertNotIn("revoked", responses[0][1])
        self.assertEqual(self.read_oauth_connection(), replacement)
        self.assertEqual(self.oauth_audit_count(), 0)

    def test_failed_provider_refresh_leaves_saved_grant_and_audit_unchanged(self):
        original = self.seed_oauth_connection()
        handler, responses = self.oauth_handler()
        with mock.patch.object(self.backend, "qbo_request", return_value=(500, {"error": "fixture-secret"})):
            handler.refresh_qbo_access_token()
        self.assertEqual(responses[0][0], 502)
        self.assertNotIn("fixture-secret", str(responses))
        self.assertEqual(self.read_oauth_connection(), original)
        self.assertEqual(self.oauth_audit_count(), 0)

    def test_oauth_audit_failure_rolls_back_rotation_and_returns_no_token(self):
        original = self.seed_oauth_connection()
        handler, responses = self.oauth_handler()
        with mock.patch.object(self.backend, "qbo_request", return_value=(200, {
            "access_token": "fixture-access", "refresh_token": "fixture-rotated", "expires_in": 3600,
        })), mock.patch.object(self.backend, "record_audit_event", side_effect=RuntimeError("fixture storage failure")):
            with self.assertRaises(RuntimeError):
                handler.refresh_qbo_access_token()
        self.assertEqual(responses, [])
        self.assertEqual(self.read_oauth_connection(), original)


if __name__ == "__main__":
    unittest.main()
