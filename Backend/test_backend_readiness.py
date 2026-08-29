from __future__ import annotations

import base64
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
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from Backend import gunnaire_backend as backend


class BackendReadinessTests(unittest.TestCase):
    def readiness_configuration(self, root: Path) -> mock._patch_dict:
        database = root / "gunnaire_backend.sqlite3"
        storage = root / "storage"
        backup_status = root / "backup_status.json"
        apns_private_key = ec.generate_private_key(ec.SECP256R1()).private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        return mock.patch.multiple(
            backend,
            DATA_ROOT=root,
            DB_PATH=database,
            STORAGE_ROOT=storage,
            BACKUP_STATUS_PATH=backup_status,
            AUTH_MODE="google-id-token",
            CUSTOMER_PORTAL_ENABLED=True,
            CUSTOMER_PORTAL_BASE_URL="https://portal.gunnaire.com",
            QBO_CLIENT_ID="production-client",
            QBO_CLIENT_SECRET="server-secret",
            QBO_REDIRECT_URI="https://gunnaire.com/qbo/callback",
            QBO_ENVIRONMENT="production",
            QBO_TOKEN_ENCRYPTION_KEY=Fernet.generate_key().decode("utf-8"),
            QBO_WEBHOOK_VERIFIER_TOKEN="webhook-verifier-token",
            PUSH_TOKEN_ENCRYPTION_KEY=Fernet.generate_key().decode("utf-8"),
            APNS_TEAM_ID="7C4B3RR7RD",
            APNS_KEY_ID="A1B2C3D4E5",
            APNS_PRIVATE_KEY_BASE64=base64.b64encode(apns_private_key).decode("ascii"),
            APNS_TOPIC="com.gunnaire.businesssuite",
            apns_provider_dependency_is_available=mock.Mock(return_value=True),
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
            connection.execute(
                """
                INSERT INTO qbo_accounting_config(
                    realm_id, environment,
                    default_sales_item_ref, default_sales_item_name, default_sales_item_type,
                    default_income_account_ref, default_income_account_name, default_income_account_type,
                    default_expense_account_ref, default_expense_account_name, default_expense_account_type,
                    default_bank_account_ref, default_bank_account_name, default_bank_account_type,
                    default_credit_card_account_ref, default_credit_card_account_name,
                    default_credit_card_account_type, updated_at, updated_by
                ) VALUES (
                    'realm-123', 'production',
                    '101', 'HVAC Service', 'Service',
                    '201', 'Service Income', 'Income',
                    '301', 'Cost of Goods Sold', 'Cost of Goods Sold',
                    '401', 'Operating Checking', 'Bank',
                    '501', 'Company Credit Card', 'Credit Card', ?, 'admin@gunnaire.com'
                )
                """,
                (now.isoformat(),),
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
                "customer-portal": "ready",
                "quickbooks": "ready",
                "quickbooks-accounting-config": "ready",
                "quickbooks-webhooks": "ready",
                "push-notifications": "ready",
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

    def test_push_readiness_surfaces_missing_http2_provider_dependency_as_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.readiness_configuration(root):
                backend.initialize_database()
                with mock.patch.object(
                    backend,
                    "apns_provider_dependency_is_available",
                    return_value=False,
                ):
                    component = backend.push_notification_readiness_component()

        self.assertEqual(component["status"], "error")
        self.assertEqual(
            component["detail"],
            "The HTTP/2 APNs provider dependency is unavailable on this server.",
        )

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
                    self.assertEqual(len(payload["components"]), 10)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
