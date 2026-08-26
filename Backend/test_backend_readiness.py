from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet

from Backend import gunnaire_backend as backend


class BackendReadinessTests(unittest.TestCase):
    def readiness_configuration(self, root: Path) -> mock._patch_dict:
        database = root / "gunnaire_backend.sqlite3"
        storage = root / "storage"
        backup_status = root / "backup_status.json"
        return mock.patch.multiple(
            backend,
            DATA_ROOT=root,
            DB_PATH=database,
            STORAGE_ROOT=storage,
            BACKUP_STATUS_PATH=backup_status,
            AUTH_MODE="google-id-token",
            QBO_CLIENT_ID="production-client",
            QBO_CLIENT_SECRET="server-secret",
            QBO_REDIRECT_URI="https://gunnaire.com/qbo/callback",
            QBO_ENVIRONMENT="production",
            QBO_TOKEN_ENCRYPTION_KEY=Fernet.generate_key().decode("utf-8"),
            QBO_WEBHOOK_VERIFIER_TOKEN="webhook-verifier-token",
        )

    def seed_ready_state(self, root: Path, now: datetime) -> None:
        backend.initialize_database()
        backend.STORAGE_ROOT.mkdir(parents=True, exist_ok=True)
        encrypted_token = backend.encrypt_qbo_refresh_token("server-only-refresh-token")
        fingerprint = backend.hashlib.sha256(backend.QBO_CLIENT_ID.encode("utf-8")).hexdigest()
        with backend.db() as connection:
            connection.execute(
                """
                INSERT INTO qbo_connections(
                    id, realm_id, refresh_token_ciphertext, environment,
                    client_id_fingerprint, authorized_at, updated_at
                ) VALUES (1, 'realm-123', ?, 'production', ?, ?, ?)
                """,
                (encrypted_token, fingerprint, now.isoformat(), now.isoformat()),
            )
            connection.execute(
                """
                INSERT INTO qbo_webhook_events(
                    event_id, realm_id, entity_type, entity_id, operation,
                    occurred_at, received_at
                ) VALUES ('event-ready-1', 'realm-123', 'invoice', '42', 'updated', ?, ?)
                """,
                (now.isoformat(), now.isoformat()),
            )
        backend.BACKUP_STATUS_PATH.write_text(
            json.dumps({"artifactID": "backup-verified-123", "verifiedAt": now.isoformat()}),
            encoding="utf-8",
        )

    def test_ready_snapshot_requires_durable_data_auth_qbo_and_recent_backup(self) -> None:
        now = datetime(2026, 8, 26, 20, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.readiness_configuration(root):
                self.seed_ready_state(root, now)

                snapshot = backend.backend_readiness_snapshot(now=now)

        self.assertEqual(snapshot["status"], "ready")
        self.assertEqual(snapshot["serviceVersion"], backend.SERVICE_VERSION)
        statuses = {component["id"]: component["status"] for component in snapshot["components"]}
        self.assertEqual(
            statuses,
            {
                "persistent-data": "ready",
                "database": "ready",
                "storage": "ready",
                "authentication": "ready",
                "quickbooks": "ready",
                "quickbooks-webhooks": "ready",
                "backup": "ready",
            },
        )

    def test_snapshot_surfaces_missing_backup_and_company_authorization_as_attention(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.readiness_configuration(root):
                backend.initialize_database()
                snapshot = backend.backend_readiness_snapshot()

        self.assertEqual(snapshot["status"], "attention")
        statuses = {component["id"]: component["status"] for component in snapshot["components"]}
        self.assertEqual(statuses["quickbooks"], "attention")
        self.assertEqual(statuses["backup"], "attention")

    def test_readiness_endpoint_requires_administrator_authentication(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DATA_ROOT=root,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                BACKUP_STATUS_PATH=root / "backup_status.json",
                AUTH_MODE="api-token",
                API_TOKEN="readiness-test-token",
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                url = f"http://127.0.0.1:{server.server_port}/api/readiness"
                try:
                    with self.assertRaises(urllib.error.HTTPError) as unauthorized:
                        urllib.request.urlopen(url, timeout=5)
                    self.assertEqual(unauthorized.exception.code, 401)

                    request = urllib.request.Request(
                        url,
                        headers={"Authorization": "Bearer readiness-test-token"},
                    )
                    with urllib.request.urlopen(request, timeout=5) as response:
                        payload = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 200)
                    self.assertEqual(payload["serviceVersion"], backend.SERVICE_VERSION)
                    self.assertEqual(len(payload["components"]), 7)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
