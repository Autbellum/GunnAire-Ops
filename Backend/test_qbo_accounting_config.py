from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from Backend import gunnaire_backend as backend


class QuickBooksAccountingConfigurationTests(unittest.TestCase):
    api_token = "accounting-config-admin-token"
    realm_id = "9341455327810551"

    @staticmethod
    def valid_payload() -> dict[str, str]:
        return {
            "defaultSalesItemRef": "1",
            "defaultSalesItemName": "HVAC Service",
            "defaultSalesItemType": "Service",
            "defaultIncomeAccountRef": "79",
            "defaultIncomeAccountName": "Service Income",
            "defaultIncomeAccountType": "Income",
            "defaultExpenseAccountRef": "80",
            "defaultExpenseAccountName": "HVAC Materials",
            "defaultExpenseAccountType": "Cost of Goods Sold",
            "defaultBankAccountRef": "35",
            "defaultBankAccountName": "Operating Checking",
            "defaultBankAccountType": "Bank",
            "defaultCreditCardAccountRef": "36",
            "defaultCreditCardAccountName": "Company Card",
            "defaultCreditCardAccountType": "Credit Card",
        }

    @staticmethod
    def request(
        url: str,
        *,
        token: str | None = None,
        payload: dict[str, str] | None = None,
    ) -> urllib.request.Request:
        headers = {"Accept": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        body = None
        method = "GET"
        if payload is not None:
            body = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
            method = "POST"
        return urllib.request.Request(url, data=body, method=method, headers=headers)

    @staticmethod
    def seed_connection(realm_id: str) -> None:
        with backend.db() as connection:
            connection.execute(
                """
                INSERT INTO qbo_connections(
                    id, realm_id, refresh_token_ciphertext, environment,
                    client_id_fingerprint, authorized_at, updated_at
                ) VALUES (1, ?, 'ciphertext', 'production', 'fingerprint', 'now', 'now')
                ON CONFLICT(id) DO UPDATE SET realm_id = excluded.realm_id
                """,
                (realm_id,),
            )

    def test_schema_and_validation_require_separate_bank_and_credit_card_accounts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(backend, "DB_PATH", Path(directory) / "backend.sqlite3"):
                backend.initialize_database()
                with backend.db() as connection:
                    columns = {row["name"] for row in connection.execute("PRAGMA table_info(qbo_accounting_config)")}
                self.assertTrue(
                    {
                        "realm_id",
                        "environment",
                        "default_sales_item_ref",
                        "default_income_account_ref",
                        "default_expense_account_ref",
                        "default_bank_account_ref",
                        "default_credit_card_account_ref",
                        "updated_at",
                        "updated_by",
                    }
                    <= columns
                )

                invalid = self.valid_payload()
                invalid["defaultCreditCardAccountType"] = "Bank"
                with self.assertRaises(ValueError):
                    backend.validate_qbo_accounting_configuration(invalid)

    def test_admin_can_store_and_read_realm_bound_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                AUTH_MODE="api-token",
                API_TOKEN=self.api_token,
            ):
                backend.initialize_database()
                self.seed_connection(self.realm_id)
                server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                base_url = f"http://127.0.0.1:{server.server_port}/api/qbo/accounting-config"
                try:
                    with self.assertRaises(urllib.error.HTTPError) as unauthorized:
                        urllib.request.urlopen(self.request(base_url), timeout=5)
                    self.assertEqual(unauthorized.exception.code, 401)

                    with urllib.request.urlopen(
                        self.request(base_url, token=self.api_token), timeout=5
                    ) as response:
                        empty = json.loads(response.read().decode("utf-8"))
                    self.assertIsNone(empty["configuration"])

                    with urllib.request.urlopen(
                        self.request(base_url, token=self.api_token, payload=self.valid_payload()),
                        timeout=5,
                    ) as response:
                        stored = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(stored["realmID"], self.realm_id)
                    self.assertEqual(stored["environment"], "production")
                    self.assertEqual(stored["configuration"]["defaultBankAccountRef"], "35")
                    self.assertEqual(stored["configuration"]["defaultCreditCardAccountRef"], "36")
                    self.assertNotIn("refreshToken", json.dumps(stored))

                    with backend.db() as connection:
                        audit = connection.execute(
                            "SELECT * FROM audit_events WHERE subject_type = 'qbo-accounting-config'"
                        ).fetchone()
                    self.assertIsNotNone(audit)

                    self.seed_connection("999999")
                    with urllib.request.urlopen(
                        self.request(base_url, token=self.api_token), timeout=5
                    ) as response:
                        other_realm = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(other_realm["realmID"], "999999")
                    self.assertIsNone(other_realm["configuration"])
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_invalid_mapping_is_rejected_without_persistence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                AUTH_MODE="api-token",
                API_TOKEN=self.api_token,
            ):
                backend.initialize_database()
                self.seed_connection(self.realm_id)
                server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    invalid = self.valid_payload()
                    invalid["defaultExpenseAccountType"] = "Bank"
                    url = f"http://127.0.0.1:{server.server_port}/api/qbo/accounting-config"
                    with self.assertRaises(urllib.error.HTTPError) as rejected:
                        urllib.request.urlopen(
                            self.request(url, token=self.api_token, payload=invalid), timeout=5
                        )
                    self.assertEqual(rejected.exception.code, 400)
                    with backend.db() as connection:
                        count = connection.execute("SELECT COUNT(*) FROM qbo_accounting_config").fetchone()[0]
                    self.assertEqual(count, 0)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_active_non_admin_can_read_but_cannot_change_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                AUTH_MODE="google-id-token",
            ):
                backend.initialize_database()
                self.seed_connection(self.realm_id)
                email = "tech@gunnaire.com"
                with backend.db() as connection:
                    connection.execute(
                        "INSERT INTO users(email, role, is_active, created_at, updated_at) VALUES (?, 'Field Technician', 1, 'now', 'now')",
                        (email,),
                    )
                session_token, _ = backend.create_app_session(email, "google", "tech-subject")
                server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                url = f"http://127.0.0.1:{server.server_port}/api/qbo/accounting-config"
                try:
                    with urllib.request.urlopen(
                        self.request(url, token=session_token), timeout=5
                    ) as response:
                        readable = json.loads(response.read().decode("utf-8"))
                    self.assertIsNone(readable["configuration"])

                    with self.assertRaises(urllib.error.HTTPError) as forbidden:
                        urllib.request.urlopen(
                            self.request(url, token=session_token, payload=self.valid_payload()), timeout=5
                        )
                    self.assertEqual(forbidden.exception.code, 403)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
