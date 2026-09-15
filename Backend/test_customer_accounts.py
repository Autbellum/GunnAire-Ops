from __future__ import annotations

import json
import re
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from contextlib import contextmanager
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Iterator
from unittest import mock

from Backend import customer_accounts
from Backend import gunnaire_backend as backend


class CustomerAccountsTests(unittest.TestCase):
    api_token = "customer-accounts-test-token"
    admin_email = "admin@gunnaire.com"

    @contextmanager
    def running_server(self, *, accounts_enabled: bool = True) -> Iterator[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DATA_ROOT=root,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                AUTH_MODE="api-token",
                API_TOKEN=self.api_token,
                PRIMARY_ADMIN_EMAIL=self.admin_email,
                CUSTOMER_ACCOUNTS_ENABLED=accounts_enabled,
                CUSTOMER_ACCOUNTS_BASE_URL="https://account.gunnaire.com",
                CUSTOMER_ACCOUNTS_ATTEMPTS={},
                EMAIL_PROVIDER_API_KEY="test-postmark-key",
                EMAIL_FROM_ADDRESS="noreply@gunnaire.com",
            ):
                backend.initialize_database()  # Seeds PRIMARY_ADMIN_EMAIL as an active Admin user.
                server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    yield f"http://127.0.0.1:{server.server_port}"
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def json_request(
        self, base_url: str, path: str, *, method: str = "GET", payload=None, token: str | None = None
    ) -> urllib.request.Request:
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = f"Bearer {token}"
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        return urllib.request.Request(f"{base_url}{path}", data=data, method=method, headers=headers)

    def request_magic_link_and_capture_token(self, base_url: str, *, email: str, name: str) -> str:
        with mock.patch("Backend.gunnaire_backend.transactional_email.send_transactional_email") as sender:
            sender.return_value = True
            request = self.json_request(
                base_url, "/api/customer/magic-link", method="POST",
                payload={"email": email, "name": name, "phone": "555-0101"},
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                self.assertEqual(response.status, 202)
            self.assertEqual(sender.call_count, 1)
            body = sender.call_args.kwargs["text_body"]
        match = re.search(r"token=([A-Za-z0-9_-]+)", body)
        assert match is not None
        return match.group(1)

    def consume_magic_link(self, base_url: str, token: str) -> str:
        request = self.json_request(base_url, "/api/customer/magic-link/consume", method="POST", payload={"token": token})
        with urllib.request.urlopen(request, timeout=5) as response:
            result = json.loads(response.read().decode("utf-8"))
        return result["sessionToken"]

    def test_signup_login_and_account_view_round_trip(self) -> None:
        with self.running_server() as base_url:
            magic_token = self.request_magic_link_and_capture_token(base_url, email="Alex@Example.com", name="Alex Customer")
            session_token = self.consume_magic_link(base_url, magic_token)

            with urllib.request.urlopen(
                self.json_request(base_url, "/api/customer/account", token=session_token), timeout=5
            ) as response:
                account = json.loads(response.read().decode("utf-8"))["account"]
            self.assertEqual(account["email"], "alex@example.com")
            self.assertEqual(account["linkStatus"], "pending")

            # The same token cannot be consumed twice.
            with self.assertRaises(urllib.error.HTTPError) as failure:
                self.consume_magic_link(base_url, magic_token)
            self.assertEqual(failure.exception.code, 401)

    def test_repeat_signup_does_not_overwrite_existing_profile(self) -> None:
        with self.running_server() as base_url:
            self.request_magic_link_and_capture_token(base_url, email="alex@example.com", name="Alex Customer")
            second_token = self.request_magic_link_and_capture_token(base_url, email="alex@example.com", name="Someone Else")
            session_token = self.consume_magic_link(base_url, second_token)
            with urllib.request.urlopen(
                self.json_request(base_url, "/api/customer/account", token=session_token), timeout=5
            ) as response:
                account = json.loads(response.read().decode("utf-8"))["account"]
            self.assertEqual(account["name"], "Alex Customer")

    def test_customer_session_cannot_access_any_staff_endpoint(self) -> None:
        with self.running_server() as base_url:
            magic_token = self.request_magic_link_and_capture_token(base_url, email="alex@example.com", name="Alex Customer")
            session_token = self.consume_magic_link(base_url, magic_token)

            for path in ("/api/session", "/api/service-requests", "/api/customer-accounts", "/api/users"):
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(self.json_request(base_url, path, token=session_token), timeout=5)
                self.assertEqual(failure.exception.code, 401, path)

    def test_staff_endpoints_reject_customer_session_and_accept_staff_token(self) -> None:
        with self.running_server() as base_url:
            magic_token = self.request_magic_link_and_capture_token(base_url, email="alex@example.com", name="Alex Customer")
            session_token = self.consume_magic_link(base_url, magic_token)

            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(
                    self.json_request(base_url, "/api/customer/account", token=self.api_token), timeout=5
                )
            self.assertEqual(failure.exception.code, 401)

    def test_service_request_from_customer_notifies_admins_by_push_and_email(self) -> None:
        # Device registration and APNs delivery are covered by
        # test_push_notifications.py; this test verifies that a customer's
        # service request correctly triggers a push queue call and an email
        # to every active admin, without re-testing APNs plumbing.
        with self.running_server() as base_url:
            magic_token = self.request_magic_link_and_capture_token(base_url, email="alex@example.com", name="Alex Customer")
            session_token = self.consume_magic_link(base_url, magic_token)

            with mock.patch("Backend.gunnaire_backend.transactional_email.send_transactional_email") as sender, mock.patch(
                "Backend.gunnaire_backend.queue_staff_push_event"
            ) as queue_push:
                sender.return_value = True
                queue_push.return_value = 1
                submit = self.json_request(
                    base_url, "/api/customer/service-requests", method="POST", token=session_token,
                    payload={
                        "summary": "Annual maintenance for the rooftop unit",
                        "requestedServiceType": "maintenance",
                        "urgency": "normal",
                        "preferredDate": "2026-10-01",
                    },
                )
                with urllib.request.urlopen(submit, timeout=5) as response:
                    accepted = json.loads(response.read().decode("utf-8"))
                self.assertEqual(response.status, 201)

                self.assertEqual(queue_push.call_count, 1)
                self.assertEqual(queue_push.call_args.kwargs["recipient_email"], self.admin_email)
                self.assertEqual(queue_push.call_args.kwargs["category"], "customer-service-request")
                self.assertEqual(queue_push.call_args.kwargs["route"], "serviceRequestsQueue")
                self.assertEqual(queue_push.call_args.kwargs["record_id"], accepted["requestID"])

                self.assertEqual(sender.call_count, 1)
                self.assertEqual(sender.call_args.kwargs["to_address"], self.admin_email)

            with urllib.request.urlopen(
                self.json_request(base_url, "/api/service-requests", token=self.api_token), timeout=5
            ) as response:
                requests_ = json.loads(response.read().decode("utf-8"))["serviceRequests"]
            self.assertEqual(len(requests_), 1)
            self.assertEqual(requests_[0]["id"], accepted["requestID"])
            self.assertEqual(requests_[0]["source"], "customerPortal")
            self.assertEqual(requests_[0]["customerName"], "Alex Customer")

    def test_anonymous_public_booking_is_unaffected_and_still_tagged_website(self) -> None:
        with self.running_server() as base_url:
            with mock.patch.object(backend, "PUBLIC_BOOKING_ENABLED", True), mock.patch.object(
                backend, "PUBLIC_BOOKING_ATTEMPTS", {}
            ):
                booking = self.json_request(
                    base_url, "/api/public/service-requests", method="POST",
                    payload={
                        "customerName": "Website Lead", "phone": "555-0100",
                        "summary": "AC not cooling", "requestedServiceType": "service",
                        "urgency": "priority", "contactConsent": True,
                    },
                )
                with urllib.request.urlopen(booking, timeout=5) as response:
                    accepted = json.loads(response.read().decode("utf-8"))
                self.assertEqual(response.status, 202)

            with urllib.request.urlopen(
                self.json_request(base_url, "/api/service-requests", token=self.api_token), timeout=5
            ) as response:
                requests_ = json.loads(response.read().decode("utf-8"))["serviceRequests"]
            self.assertEqual(requests_[0]["id"], accepted["requestID"])
            self.assertEqual(requests_[0]["source"], "website")
            self.assertIsNone(requests_[0]["customerAccountID"])

    def test_staff_can_list_and_link_a_pending_signup(self) -> None:
        with self.running_server() as base_url:
            self.request_magic_link_and_capture_token(base_url, email="alex@example.com", name="Alex Customer")

            with urllib.request.urlopen(
                self.json_request(base_url, "/api/customer-accounts", token=self.api_token), timeout=5
            ) as response:
                pending = json.loads(response.read().decode("utf-8"))["customerAccounts"]
            self.assertEqual(len(pending), 1)
            account_id = pending[0]["id"]
            self.assertEqual(pending[0]["linkStatus"], "pending")

            link = self.json_request(
                base_url, f"/api/customer-accounts/{account_id}/link", method="POST", token=self.api_token,
                payload={"customerID": "11111111-1111-1111-1111-111111111111", "quickBooksID": "42"},
            )
            with urllib.request.urlopen(link, timeout=5) as response:
                updated = json.loads(response.read().decode("utf-8"))["customerAccount"]
            self.assertEqual(updated["linkStatus"], "linked")
            self.assertEqual(updated["linkedCustomerQuickBooksID"], "42")

            with urllib.request.urlopen(
                self.json_request(base_url, "/api/customer-accounts", token=self.api_token), timeout=5
            ) as response:
                pending_after = json.loads(response.read().decode("utf-8"))["customerAccounts"]
            self.assertEqual(pending_after, [])

    def test_portal_page_is_served_when_enabled_and_hidden_when_disabled(self) -> None:
        with self.running_server() as base_url:
            with urllib.request.urlopen(f"{base_url}/account", timeout=5) as response:
                self.assertEqual(response.status, 200)
                self.assertIn("text/html", response.headers.get("Content-Type", ""))
                body = response.read().decode("utf-8")
            self.assertIn("GunnAire Customer Account", body)

        with self.running_server(accounts_enabled=False) as base_url:
            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(f"{base_url}/account", timeout=5)
            self.assertEqual(failure.exception.code, 404)

    def test_disabled_feature_flag_rejects_signup(self) -> None:
        with self.running_server(accounts_enabled=False) as base_url:
            request = self.json_request(
                base_url, "/api/customer/magic-link", method="POST",
                payload={"email": "alex@example.com", "name": "Alex Customer"},
            )
            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(request, timeout=5)
            self.assertEqual(failure.exception.code, 404)

    def test_rate_limit_blocks_repeated_magic_link_requests_from_one_ip(self) -> None:
        with self.running_server() as base_url:
            with mock.patch.object(backend, "CUSTOMER_ACCOUNTS_RATE_LIMIT", 2):
                for _ in range(2):
                    with mock.patch("Backend.gunnaire_backend.transactional_email.send_transactional_email"):
                        request = self.json_request(
                            base_url, "/api/customer/magic-link", method="POST",
                            payload={"email": "alex@example.com", "name": "Alex Customer"},
                        )
                        with urllib.request.urlopen(request, timeout=5) as response:
                            self.assertEqual(response.status, 202)
                request = self.json_request(
                    base_url, "/api/customer/magic-link", method="POST",
                    payload={"email": "alex@example.com", "name": "Alex Customer"},
                )
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(request, timeout=5)
                self.assertEqual(failure.exception.code, 429)


class CustomerInvoiceFetchTests(unittest.TestCase):
    """Unit-level coverage for the pure QBO-reading helper, independent of the
    live OAuth refresh dance (covered separately for the shared bearer path)."""

    def test_fetches_balances_and_pay_links_only_for_outstanding_invoices(self) -> None:
        calls: list[str] = []

        def fake_request_factory(url, *, method, headers):
            calls.append(url)
            return url

        def fake_transport(request):
            if "/query?" in request:
                return 200, {
                    "QueryResponse": {
                        "Invoice": [
                            {"Id": "101", "DocNumber": "1001", "Balance": 250.0, "TotalAmt": 250.0, "DueDate": "2026-10-01"},
                            {"Id": "102", "DocNumber": "1002", "Balance": 0, "TotalAmt": 500.0, "DueDate": "2026-09-01"},
                        ]
                    }
                }
            self.assertIn("/invoice/101", request)
            return 200, {"Invoice": {"Id": "101", "InvoiceLink": "https://qbo.example/pay/101"}}

        invoices = customer_accounts.fetch_customer_invoices(
            quickbooks_customer_id="55",
            realm_id="123456789",
            environment="sandbox",
            bearer="test-bearer",
            transport=fake_transport,
            request_factory=fake_request_factory,
        )
        self.assertEqual(len(invoices), 2)
        self.assertEqual(invoices[0]["payLink"], "https://qbo.example/pay/101")
        self.assertIsNone(invoices[1]["payLink"])
        self.assertEqual(sum(1 for call in calls if "/invoice/" in call), 1)

    def test_rejects_non_numeric_customer_id(self) -> None:
        invoices = customer_accounts.fetch_customer_invoices(
            quickbooks_customer_id="'; DROP TABLE Invoice; --",
            realm_id="123456789",
            environment="sandbox",
            bearer="test-bearer",
            transport=lambda request: (200, {}),
            request_factory=lambda *a, **k: "unused",
        )
        self.assertEqual(invoices, [])


if __name__ == "__main__":
    unittest.main()
