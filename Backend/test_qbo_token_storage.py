"""Regression coverage for the confidential QuickBooks OAuth token boundary."""

from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
