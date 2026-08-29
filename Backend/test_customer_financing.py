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


class CustomerFinancingTests(unittest.TestCase):
    api_token = "customer-financing-test-token"

    def financing_configuration(self, **overrides: object):
        configuration: dict[str, object] = {
            "CUSTOMER_FINANCING_ENABLED": True,
            "CUSTOMER_FINANCING_PROVIDER_NAME": "Approved HVAC Finance",
            "CUSTOMER_FINANCING_APPLICATION_URL": "https://finance.example.com/gunnaire/apply",
            "CUSTOMER_FINANCING_MIN_AMOUNT": "500",
            "CUSTOMER_FINANCING_MAX_AMOUNT": "50000",
        }
        configuration.update(overrides)
        return mock.patch.multiple(backend, **configuration)

    @staticmethod
    def serve() -> tuple[ThreadingHTTPServer, threading.Thread, str]:
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        return server, thread, f"http://127.0.0.1:{server.server_port}"

    def test_disabled_contract_contains_no_provider_url_or_submission_capability(self) -> None:
        with self.financing_configuration(
            CUSTOMER_FINANCING_ENABLED=False,
            CUSTOMER_FINANCING_PROVIDER_NAME="secret-provider-name",
            CUSTOMER_FINANCING_APPLICATION_URL="https://user:password@finance.example.com/apply",
        ):
            result = backend.customer_financing_readiness()

        self.assertEqual(result["contractVersion"], 1)
        self.assertEqual(result["status"], "disabled")
        self.assertIsNone(result["providerName"])
        self.assertIsNone(result["applicationURL"])
        self.assertTrue(result["providerHostedApplication"])
        self.assertFalse(result["canSubmitApplication"])
        serialized = json.dumps(result).lower()
        self.assertNotIn("password", serialized)
        self.assertNotIn("secret-provider-name", serialized)

    def test_ready_contract_returns_only_static_provider_handoff_configuration(self) -> None:
        with self.financing_configuration():
            result = backend.customer_financing_readiness()

        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["providerName"], "Approved HVAC Finance")
        self.assertEqual(result["applicationURL"], "https://finance.example.com/gunnaire/apply")
        self.assertEqual(result["minimumAmount"], 500.0)
        self.assertEqual(result["maximumAmount"], 50000.0)
        self.assertTrue(result["providerHostedApplication"])
        self.assertFalse(result["canSubmitApplication"])
        serialized = json.dumps(result).lower()
        for forbidden in ("customer", "estimateid", "ssn", "creditdecision", "token", "secret"):
            self.assertNotIn(forbidden, serialized)

    def test_invalid_urls_and_amount_limits_fail_closed(self) -> None:
        invalid_configurations = [
            {"CUSTOMER_FINANCING_APPLICATION_URL": "http://finance.example.com/apply"},
            {"CUSTOMER_FINANCING_APPLICATION_URL": "https://user:password@finance.example.com/apply"},
            {"CUSTOMER_FINANCING_APPLICATION_URL": "https://finance.example.com/apply#customer"},
            {"CUSTOMER_FINANCING_MIN_AMOUNT": "not-a-number"},
            {"CUSTOMER_FINANCING_MIN_AMOUNT": "60000", "CUSTOMER_FINANCING_MAX_AMOUNT": "50000"},
            {"CUSTOMER_FINANCING_MAX_AMOUNT": "0"},
        ]
        for configuration in invalid_configurations:
            with self.subTest(configuration=configuration), self.financing_configuration(**configuration):
                result = backend.customer_financing_readiness()
            self.assertEqual(result["status"], "attention")
            self.assertIsNone(result["applicationURL"])
            self.assertFalse(result["canSubmitApplication"])

    def test_endpoint_requires_authentication_and_returns_same_read_only_contract_to_active_staff(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                AUTH_MODE="api-token",
                API_TOKEN=self.api_token,
            ), self.financing_configuration():
                backend.initialize_database()
                server, thread, base_url = self.serve()
                url = f"{base_url}/api/customer-financing"
                try:
                    with self.assertRaises(urllib.error.HTTPError) as unauthorized:
                        urllib.request.urlopen(url, timeout=5)
                    self.assertEqual(unauthorized.exception.code, 401)

                    request = urllib.request.Request(
                        url,
                        headers={"Authorization": f"Bearer {self.api_token}"},
                    )
                    with urllib.request.urlopen(request, timeout=5) as response:
                        payload = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 200)
                    self.assertEqual(payload, backend.customer_financing_readiness())
                    self.assertFalse(payload["canSubmitApplication"])
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
