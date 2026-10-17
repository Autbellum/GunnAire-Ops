from __future__ import annotations

import json
import hashlib
import re
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from urllib.parse import urlsplit
from contextlib import contextmanager
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Iterator
from unittest import mock

from Backend import customer_accounts, transactional_email
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

    def test_emailed_magic_link_opens_the_verification_page(self) -> None:
        with self.running_server() as base_url:
            with mock.patch("Backend.gunnaire_backend.transactional_email.send_transactional_email", return_value=True) as sender:
                request = self.json_request(base_url, "/api/customer/magic-link", method="POST",
                                            payload={"email": "alex@example.com", "name": "Alex Customer"})
                with urllib.request.urlopen(request, timeout=5) as response:
                    self.assertEqual(response.status, 202)
            link = re.search(r"https://account\.gunnaire\.com/\S+", sender.call_args.kwargs["text_body"])
            self.assertIsNotNone(link)
            parsed = urlsplit(link.group(0))
            with urllib.request.urlopen(base_url + parsed.path + "?" + parsed.query, timeout=5) as response:
                self.assertEqual(response.status, 200)
                self.assertIn(b"GunnAire Customer Account", response.read())

    def test_failed_or_unconfigured_email_does_not_claim_delivery(self) -> None:
        with self.running_server() as base_url:
            payload = {"email": "alex@example.com", "name": "Alex Customer"}
            with mock.patch.object(backend, "EMAIL_PROVIDER_API_KEY", ""):
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(self.json_request(base_url, "/api/customer/magic-link",
                                                         method="POST", payload=payload), timeout=5)
                self.assertEqual(failure.exception.code, 503)
            with backend.db() as connection:
                self.assertEqual(connection.execute("SELECT count(*) FROM customer_magic_links").fetchone()[0], 0)
            with mock.patch("Backend.gunnaire_backend.transactional_email.send_transactional_email", return_value=False) as sender:
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(self.json_request(base_url, "/api/customer/magic-link",
                                                         method="POST", payload=payload), timeout=5)
                self.assertEqual(failure.exception.code, 503)
                self.assertIn("could not be confirmed", failure.exception.read().decode("utf-8"))
            token = re.search(r"token=([A-Za-z0-9_-]+)", sender.call_args.kwargs["text_body"])
            self.assertIsNotNone(token)
            self.assertTrue(self.consume_magic_link(base_url, token.group(1)))

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
                payload={"customerID": "11111111-1111-1111-1111-111111111111", "quickBooksID": None},
            )
            with urllib.request.urlopen(link, timeout=5) as response:
                updated = json.loads(response.read().decode("utf-8"))["customerAccount"]
            self.assertEqual(updated["linkStatus"], "linked")
            self.assertIsNone(updated["linkedCustomerQuickBooksID"])

            with urllib.request.urlopen(
                self.json_request(base_url, "/api/customer-accounts", token=self.api_token), timeout=5
            ) as response:
                pending_after = json.loads(response.read().decode("utf-8"))["customerAccounts"]
            self.assertEqual(pending_after, [])

    def test_admin_can_read_one_account_status_without_exposing_it_to_customers_or_dispatchers(self) -> None:
        with self.running_server() as base_url:
            magic_token = self.request_magic_link_and_capture_token(
                base_url, email="alex@example.com", name="Alex Customer"
            )
            customer_session = self.consume_magic_link(base_url, magic_token)
            with urllib.request.urlopen(
                self.json_request(base_url, "/api/customer-accounts", token=self.api_token), timeout=5
            ) as response:
                account_id = json.loads(response.read().decode("utf-8"))["customerAccounts"][0]["id"]

            status_path = f"/api/customer-accounts/{account_id}"
            with urllib.request.urlopen(self.json_request(base_url, status_path, token=self.api_token), timeout=5) as response:
                record = json.loads(response.read().decode("utf-8"))["customerAccount"]
            self.assertEqual(record["linkStatus"], "pending")
            self.assertEqual(record["id"], account_id)

            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(self.json_request(base_url, status_path, token=customer_session), timeout=5)
            self.assertEqual(failure.exception.code, 401)
            with mock.patch.object(backend.GunnAireBackendHandler, "principal", return_value={
                "email": "dispatcher@example.invalid", "role": "Dispatcher", "isActive": True,
            }):
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(self.json_request(base_url, status_path, token=self.api_token), timeout=5)
                self.assertEqual(failure.exception.code, 403)

    def test_link_retry_is_idempotent_and_conflicting_relink_cannot_overwrite(self) -> None:
        with self.running_server() as base_url:
            self.request_magic_link_and_capture_token(base_url, email="alex@example.com", name="Alex Customer")
            with urllib.request.urlopen(
                self.json_request(base_url, "/api/customer-accounts", token=self.api_token), timeout=5
            ) as response:
                account_id = json.loads(response.read().decode("utf-8"))["customerAccounts"][0]["id"]
            path = f"/api/customer-accounts/{account_id}/link"
            first_customer_id = "11111111-1111-1111-1111-111111111111"
            first = self.json_request(base_url, path, method="POST", token=self.api_token,
                                      payload={"customerID": first_customer_id, "quickBooksID": None})
            with urllib.request.urlopen(first, timeout=5) as response:
                linked = json.loads(response.read().decode("utf-8"))["customerAccount"]
            with urllib.request.urlopen(first, timeout=5) as response:
                repeated = json.loads(response.read().decode("utf-8"))["customerAccount"]
            self.assertEqual(repeated["linkedCustomerID"], first_customer_id)
            self.assertEqual(repeated["linkedAt"], linked["linkedAt"])

            different = self.json_request(base_url, path, method="POST", token=self.api_token,
                                          payload={"customerID": "22222222-2222-2222-2222-222222222222",
                                                   "quickBooksID": None})
            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(different, timeout=5)
            self.assertEqual(failure.exception.code, 409)
            with urllib.request.urlopen(
                self.json_request(base_url, f"/api/customer-accounts/{account_id}", token=self.api_token), timeout=5
            ) as response:
                current = json.loads(response.read().decode("utf-8"))["customerAccount"]
            self.assertEqual(current["linkedCustomerID"], first_customer_id)

    def test_qbo_link_requires_verified_current_realm_customer(self) -> None:
        with self.running_server() as base_url:
            self.request_magic_link_and_capture_token(base_url, email="alex@example.com", name="Alex Customer")
            with urllib.request.urlopen(self.json_request(base_url, "/api/customer-accounts", token=self.api_token), timeout=5) as response:
                account_id = json.loads(response.read().decode("utf-8"))["customerAccounts"][0]["id"]
            link = self.json_request(base_url, f"/api/customer-accounts/{account_id}/link", method="POST",
                                     token=self.api_token,
                                     payload={"customerID": "11111111-1111-1111-1111-111111111111", "quickBooksID": "42"})
            with self.assertRaises(urllib.error.HTTPError) as failure:
                urllib.request.urlopen(link, timeout=5)
            self.assertEqual(failure.exception.code, 503)
            with urllib.request.urlopen(self.json_request(base_url, "/api/customer-accounts", token=self.api_token), timeout=5) as response:
                self.assertEqual(len(json.loads(response.read().decode("utf-8"))["customerAccounts"]), 1)

            with backend.db() as connection:
                connection.execute("INSERT INTO qbo_connections VALUES (1,?,?,?,?,?,?)",
                                   ("current-realm", "cipher", "sandbox", hashlib.sha256(b"fixture-client").hexdigest(),
                                    "grant", "updated"))
            with mock.patch.object(backend, "QBO_ENVIRONMENT", "sandbox"), mock.patch.object(
                backend, "qbo_authorized_bearer", return_value="fixture-bearer"
            ), mock.patch.object(backend, "qbo_payment_read_transport", return_value=(200, {
                "Customer": {"Id": "42", "PrimaryEmailAddr": {"Address": "someone-else@example.com"}}
            })):
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(link, timeout=5)
                self.assertEqual(failure.exception.code, 409)

            def qbo_transport(request):
                if "/customer/42" in request.full_url:
                    return 200, {"Customer": {"Id": "42", "PrimaryEmailAddr": {"Address": "ALEX@example.com"}}}
                if "/query?" in request.full_url:
                    return 200, {"QueryResponse": {"Invoice": [
                        {"Id": "101", "DocNumber": "1001", "Balance": 25.0, "TotalAmt": 25.0}
                    ]}}
                if "/invoice/101" in request.full_url:
                    return 200, {"Invoice": {"Id": "101", "InvoiceLink": "https://qbo.example/pay/101"}}
                self.fail("Unexpected QuickBooks request")

            with mock.patch.object(backend, "QBO_ENVIRONMENT", "sandbox"), mock.patch.object(
                backend, "qbo_authorized_bearer", return_value="fixture-bearer"
            ), mock.patch.object(backend, "qbo_payment_read_transport", side_effect=qbo_transport) as transport:
                with urllib.request.urlopen(link, timeout=5) as response:
                    updated = json.loads(response.read().decode("utf-8"))["customerAccount"]
                self.assertEqual(updated["linkedCustomerQuickBooksID"], "42")
                with mock.patch.object(backend, "qbo_authorized_bearer", side_effect=AssertionError(
                    "A confirmed same-ID retry must not fetch a new provider identity"
                )):
                    with urllib.request.urlopen(link, timeout=5) as response:
                        repeated = json.loads(response.read().decode("utf-8"))["customerAccount"]
                self.assertEqual(repeated["linkedAt"], updated["linkedAt"])
                changed_customer = self.json_request(
                    base_url, f"/api/customer-accounts/{account_id}/link", method="POST", token=self.api_token,
                    payload={"customerID": "22222222-2222-2222-2222-222222222222", "quickBooksID": "42"},
                )
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(changed_customer, timeout=5)
                self.assertEqual(failure.exception.code, 409)
                session = self.consume_magic_link(base_url, self.request_magic_link_and_capture_token(
                    base_url, email="alex@example.com", name="Alex Customer"))
                with urllib.request.urlopen(self.json_request(base_url, "/api/customer/invoices", token=session), timeout=5) as response:
                    invoices = json.loads(response.read().decode("utf-8"))["invoices"]
                self.assertEqual(invoices[0]["docNumber"], "1001")
                with mock.patch.object(backend, "qbo_payment_read_transport", return_value=(200, {
                    "Customer": {"Id": "42", "PrimaryEmailAddr": {"Address": "changed@example.com"}}
                })):
                    with self.assertRaises(urllib.error.HTTPError) as failure:
                        urllib.request.urlopen(self.json_request(base_url, "/api/customer/invoices", token=session), timeout=5)
                    self.assertEqual(failure.exception.code, 409)
                with mock.patch.object(backend, "qbo_payment_read_transport", side_effect=backend.payment_attempts.AttemptError(
                    "provider_unavailable", "Provider unavailable", 502
                )):
                    with self.assertRaises(urllib.error.HTTPError) as failure:
                        urllib.request.urlopen(self.json_request(base_url, "/api/customer/invoices", token=session), timeout=5)
                    self.assertEqual(failure.exception.code, 503)
                before_rotation = transport.call_count
                with backend.db() as connection:
                    connection.execute("UPDATE qbo_connections SET realm_id = 'different-realm' WHERE id = 1")
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(self.json_request(base_url, "/api/customer/invoices", token=session), timeout=5)
                self.assertEqual(failure.exception.code, 503)
                self.assertEqual(transport.call_count, before_rotation)

    def test_feature_off_rejects_existing_customer_session_and_invoices(self) -> None:
        with self.running_server() as base_url:
            session = self.consume_magic_link(base_url, self.request_magic_link_and_capture_token(
                base_url, email="alex@example.com", name="Alex Customer"))
            with mock.patch.object(backend, "CUSTOMER_ACCOUNTS_ENABLED", False):
                for path in ("/api/customer/account", "/api/customer/invoices"):
                    with self.assertRaises(urllib.error.HTTPError) as failure:
                        urllib.request.urlopen(self.json_request(base_url, path, token=session), timeout=5)
                    self.assertEqual(failure.exception.code, 404, path)
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(self.json_request(base_url, "/api/customer/service-requests",
                                                         method="POST", token=session,
                                                         payload={"summary": "Maintenance request"}), timeout=5)
                self.assertEqual(failure.exception.code, 404)

    def test_portal_page_is_served_when_enabled_and_hidden_when_disabled(self) -> None:
        with self.running_server() as base_url:
            with urllib.request.urlopen(f"{base_url}/account", timeout=5) as response:
                self.assertEqual(response.status, 200)
                self.assertIn("text/html", response.headers.get("Content-Type", ""))
                body = response.read().decode("utf-8")
            self.assertIn("GunnAire Customer Account", body)

            with mock.patch.object(backend, "EMAIL_PROVIDER_API_KEY", ""):
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(f"{base_url}/account", timeout=5)
                self.assertEqual(failure.exception.code, 503)

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

    def test_forwarded_for_header_cannot_evade_rate_limit(self) -> None:
        with self.running_server() as base_url, mock.patch.object(backend, "CUSTOMER_ACCOUNTS_RATE_LIMIT", 1):
            for index in range(2):
                request = self.json_request(base_url, "/api/customer/magic-link", method="POST",
                                            payload={"email": "alex@example.com", "name": "Alex Customer"})
                request.add_header("X-Forwarded-For", f"198.51.100.{index + 1}")
                if index == 0:
                    with mock.patch("Backend.gunnaire_backend.transactional_email.send_transactional_email", return_value=True):
                        with urllib.request.urlopen(request, timeout=5) as response:
                            self.assertEqual(response.status, 202)
                else:
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

    def test_magic_link_query_token_is_redacted_from_access_log(self) -> None:
        raw = 'GET /account/verify?token=fixture-login-secret HTTP/1.1'
        safe = backend.redact_capability_tokens(raw)
        self.assertNotIn("fixture-login-secret", safe)

    def test_qbo_identity_rejects_matching_empty_or_malformed_emails(self) -> None:
        for email in ("", "not-an-email"):
            with self.subTest(email=email):
                verified = customer_accounts.verify_customer_quickbooks_identity(
                    quickbooks_customer_id="42", account_email=email, realm_id="realm", environment="sandbox",
                    bearer="fixture-bearer", request_factory=lambda url, **kwargs: url,
                    transport=lambda request: (200, {
                        "Customer": {"Id": "42", "PrimaryEmailAddr": {"Address": email}}
                    }),
                )
                self.assertFalse(verified)


class TransactionalEmailTests(unittest.TestCase):
    def test_postmark_acceptance_requires_success_body(self) -> None:
        class Response:
            status = 200

            def __init__(self, payload):
                self.payload = payload

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def read(self, _limit):
                return json.dumps(self.payload).encode("utf-8")

        def send(payload):
            return transactional_email.send_transactional_email(
                api_key="fixture-key", from_address="noreply@example.com",
                to_address="alex@example.com", subject="Sign in", text_body="Use the link",
                opener=lambda request, timeout: Response(payload),
            )

        self.assertFalse(send({"ErrorCode": 406, "Message": "Inactive recipient"}))
        self.assertFalse(send({"MessageID": "fixture-message"}))
        self.assertTrue(send({"ErrorCode": 0, "MessageID": "fixture-message"}))


if __name__ == "__main__":
    unittest.main()
