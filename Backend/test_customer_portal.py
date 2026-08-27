from __future__ import annotations

import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Iterator
from urllib.parse import urlparse
from unittest import mock

from Backend import gunnaire_backend as backend


class FieldTechnicianPortalHandler(backend.GunnAireBackendHandler):
    def principal(self) -> dict[str, object]:
        return {
            "email": "field.tech@gunnaire.com",
            "role": "Field Technician",
            "isActive": True,
            "createdAt": None,
        }


class CustomerPortalTests(unittest.TestCase):
    api_token = "customer-portal-test-token"
    admin_email = "admin@gunnaire.com"

    @contextmanager
    def running_server(
        self,
        *,
        handler: type[backend.GunnAireBackendHandler] = backend.GunnAireBackendHandler,
        portal_enabled: bool = True,
        portal_base_url: str = "https://portal.gunnaire.com",
    ) -> Iterator[str]:
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
                CUSTOMER_PORTAL_ENABLED=portal_enabled,
                CUSTOMER_PORTAL_BASE_URL=portal_base_url,
                CUSTOMER_PORTAL_MAX_DAYS=30,
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    yield f"http://127.0.0.1:{server.server_port}"
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def portal_payload(self) -> dict[str, object]:
        return {
            "customerName": "Alex <Customer>",
            "customerEmail": "alex.customer@example.com",
            "serviceCallID": str(uuid.uuid4()),
            "invoiceID": str(uuid.uuid4()),
            "title": "Service <script>alert(1)</script> update",
            "appointmentSummary": "Friday <strong>9–11 AM</strong>",
            "invoiceReference": "INV-1042",
            "balanceDue": 456.789,
            "expiresInDays": 14,
        }

    def request(
        self,
        base_url: str,
        path: str,
        *,
        method: str = "GET",
        payload: dict[str, object] | list[object] | None = None,
        authenticated: bool = True,
    ) -> urllib.request.Request:
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["Authorization"] = f"Bearer {self.api_token}"
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        return urllib.request.Request(
            f"{base_url}{path}",
            data=data,
            method=method,
            headers=headers,
        )

    def create_link(self, base_url: str, payload: dict[str, object] | None = None) -> dict[str, object]:
        request = self.request(
            base_url,
            "/api/customer-portal-links",
            method="POST",
            payload=payload or self.portal_payload(),
        )
        with urllib.request.urlopen(request, timeout=5) as response:
            result = json.loads(response.read().decode("utf-8"))
        self.assertEqual(response.status, 201)
        return result

    def test_link_lifecycle_keeps_secret_server_side_and_tracks_non_authoritative_opens(self) -> None:
        with self.running_server() as base_url:
            source_payload = self.portal_payload()
            created = self.create_link(base_url, source_payload)
            link_id = str(created["id"])
            parsed_url = urlparse(str(created["url"]))
            token = parsed_url.path.removeprefix("/portal/")

            self.assertEqual(parsed_url.scheme, "https")
            self.assertEqual(parsed_url.netloc, "portal.gunnaire.com")
            self.assertRegex(token, r"^[A-Za-z0-9_-]{32,128}$")
            with backend.db() as connection:
                stored = connection.execute(
                    "SELECT * FROM customer_portal_links WHERE id = ?",
                    (link_id,),
                ).fetchone()
            self.assertEqual(stored["token_hash"], backend.portal_token_hash(token))
            self.assertNotEqual(stored["token_hash"], token)
            self.assertEqual(stored["opened_count"], 0)

            public_path = f"/portal/{token}"
            for expected_count in (1, 2):
                with urllib.request.urlopen(
                    self.request(base_url, public_path, authenticated=False),
                    timeout=5,
                ) as response:
                    page = response.read().decode("utf-8")
                    headers = response.headers
                self.assertEqual(response.status, 200)
                self.assertEqual(headers["Cache-Control"], "no-store")
                self.assertEqual(headers["Referrer-Policy"], "no-referrer")
                self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
                self.assertEqual(headers["X-Frame-Options"], "DENY")
                self.assertEqual(headers["Cross-Origin-Opener-Policy"], "same-origin")
                self.assertEqual(headers["Cross-Origin-Resource-Policy"], "same-origin")
                self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
                self.assertIn("payment=()", headers["Permissions-Policy"])
                self.assertIn("Alex &lt;Customer&gt;", page)
                self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", page)
                self.assertNotIn("<script>alert(1)</script>", page)
                self.assertIn("$456.79", page)
                self.assertNotIn(str(source_payload["customerEmail"]), page)
                self.assertNotIn(str(source_payload["serviceCallID"]), page)
                with backend.db() as connection:
                    opened = connection.execute(
                        "SELECT opened_count, last_opened_at FROM customer_portal_links WHERE id = ?",
                        (link_id,),
                    ).fetchone()
                self.assertEqual(opened["opened_count"], expected_count)
                self.assertIsNotNone(opened["last_opened_at"])

            with urllib.request.urlopen(
                self.request(base_url, "/api/customer-portal-links"),
                timeout=5,
            ) as response:
                records = json.loads(response.read().decode("utf-8"))["links"]
            record = records[0]
            self.assertEqual(record["id"], link_id)
            self.assertEqual(record["openedCount"], 2)
            self.assertIsNotNone(record["lastOpenedAt"])
            self.assertNotIn("url", record)
            self.assertNotIn("token", record)
            self.assertNotIn("tokenHash", record)

            with urllib.request.urlopen(
                self.request(
                    base_url,
                    f"/api/customer-portal-links/{link_id}",
                    method="DELETE",
                ),
                timeout=5,
            ) as response:
                revoked = json.loads(response.read().decode("utf-8"))
            self.assertTrue(revoked["revoked"])

            with self.assertRaises(urllib.error.HTTPError) as unavailable:
                urllib.request.urlopen(
                    self.request(base_url, public_path, authenticated=False),
                    timeout=5,
                )
            self.assertEqual(unavailable.exception.code, 404)
            with backend.db() as connection:
                actions = connection.execute(
                    "SELECT action FROM audit_events WHERE subject_id = ? ORDER BY occurred_at",
                    (link_id,),
                ).fetchall()
            self.assertEqual([row["action"] for row in actions], ["create", "revoke"])

    def test_invalid_customer_references_amounts_and_expiries_fail_closed(self) -> None:
        invalid_payloads: list[dict[str, object] | list[object]] = []
        base = self.portal_payload()
        invalid_payloads.extend(
            [
                {**base, "customerEmail": "not-an-email"},
                {**base, "serviceCallID": "not-a-uuid"},
                {**base, "invoiceID": "not-a-uuid"},
                {**base, "balanceDue": True},
                {**base, "balanceDue": -0.01},
                {**base, "balanceDue": float("nan")},
                {**base, "balanceDue": float("inf")},
                {**base, "balanceDue": 1_000_000_000},
                {**base, "expiresInDays": 1.5},
                {**base, "expiresInDays": True},
                {**base, "customerName": ["not", "text"]},
                {**base, "serviceCallID": None, "invoiceID": None},
                ["not", "an", "object"],
            ]
        )

        with self.running_server() as base_url:
            for payload in invalid_payloads:
                with self.subTest(payload=payload):
                    with self.assertRaises(urllib.error.HTTPError) as invalid:
                        urllib.request.urlopen(
                            self.request(
                                base_url,
                                "/api/customer-portal-links",
                                method="POST",
                                payload=payload,
                            ),
                            timeout=5,
                        )
                    self.assertEqual(invalid.exception.code, 400)
            with backend.db() as connection:
                count = connection.execute("SELECT COUNT(*) FROM customer_portal_links").fetchone()[0]
            self.assertEqual(count, 0)

    def test_expired_or_corrupt_links_never_render_or_increment(self) -> None:
        with self.running_server() as base_url:
            tokens = ("A" * 43, "B" * 43)
            expiries = (
                (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat(),
                "not-a-date",
            )
            with backend.db() as connection:
                for token, expires_at in zip(tokens, expiries):
                    connection.execute(
                        """
                        INSERT INTO customer_portal_links(
                            id, token_hash, customer_name, customer_email, service_call_id,
                            title, expires_at, created_at, created_by
                        ) VALUES (?, ?, 'Expired Customer', 'expired@example.com', ?,
                                  'Expired update', ?, ?, ?)
                        """,
                        (
                            str(uuid.uuid4()), backend.portal_token_hash(token), str(uuid.uuid4()),
                            expires_at, backend.utc_now(), self.admin_email,
                        ),
                    )

            for token in tokens:
                with self.assertRaises(urllib.error.HTTPError) as unavailable:
                    urllib.request.urlopen(
                        self.request(base_url, f"/portal/{token}", authenticated=False),
                        timeout=5,
                    )
                self.assertEqual(unavailable.exception.code, 404)
            with backend.db() as connection:
                counts = connection.execute(
                    "SELECT opened_count FROM customer_portal_links ORDER BY token_hash"
                ).fetchall()
            self.assertEqual([row["opened_count"] for row in counts], [0, 0])

    def test_configuration_readiness_and_token_redaction(self) -> None:
        self.assertEqual(
            backend.customer_portal_origin("https://PORTAL.GunnAire.com/"),
            "https://portal.gunnaire.com",
        )
        for invalid_origin in (
            "http://portal.gunnaire.com",
            "https://user:password@portal.gunnaire.com",
            "https://portal.gunnaire.com/customer",
            "https://portal.gunnaire.com?token=value",
            "https://portal..gunnaire.com",
        ):
            with self.subTest(origin=invalid_origin):
                self.assertIsNone(backend.customer_portal_origin(invalid_origin))

        with mock.patch.multiple(backend, CUSTOMER_PORTAL_ENABLED=False, CUSTOMER_PORTAL_BASE_URL=""):
            self.assertEqual(backend.customer_portal_readiness_component()["status"], "attention")
        with mock.patch.multiple(
            backend,
            CUSTOMER_PORTAL_ENABLED=True,
            CUSTOMER_PORTAL_BASE_URL="http://portal.gunnaire.com",
        ):
            self.assertEqual(backend.customer_portal_readiness_component()["status"], "error")
        with mock.patch.multiple(
            backend,
            CUSTOMER_PORTAL_ENABLED=True,
            CUSTOMER_PORTAL_BASE_URL="https://portal.gunnaire.com",
        ):
            component = backend.customer_portal_readiness_component()
            self.assertEqual(component["status"], "ready")
            self.assertIn("portal.gunnaire.com", component["detail"])

        token = "secret_CAPABILITY-token_12345678901234567890"
        logged = backend.redact_capability_tokens(f'"GET /portal/{token} HTTP/1.1" 200 -')
        self.assertNotIn(token, logged)
        self.assertIn("/portal/[REDACTED]", logged)

    def test_non_administrators_cannot_create_list_or_revoke_links(self) -> None:
        link_id = str(uuid.uuid4())
        with self.running_server(handler=FieldTechnicianPortalHandler) as base_url:
            requests = (
                self.request(base_url, "/api/customer-portal-links"),
                self.request(
                    base_url,
                    "/api/customer-portal-links",
                    method="POST",
                    payload=self.portal_payload(),
                ),
                self.request(
                    base_url,
                    f"/api/customer-portal-links/{link_id}",
                    method="DELETE",
                ),
            )
            for request in requests:
                with self.assertRaises(urllib.error.HTTPError) as forbidden:
                    urllib.request.urlopen(request, timeout=5)
                self.assertEqual(forbidden.exception.code, 403)

    def test_initialize_database_migrates_portal_access_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "gunnaire_backend.sqlite3"
            connection = sqlite3.connect(database)
            try:
                connection.execute(
                    """
                    CREATE TABLE customer_portal_links (
                        id TEXT PRIMARY KEY,
                        token_hash TEXT NOT NULL UNIQUE,
                        customer_name TEXT NOT NULL,
                        customer_email TEXT NOT NULL,
                        service_call_id TEXT,
                        invoice_id TEXT,
                        title TEXT NOT NULL,
                        appointment_summary TEXT,
                        invoice_reference TEXT,
                        balance_due REAL,
                        expires_at TEXT NOT NULL,
                        revoked_at TEXT,
                        created_at TEXT NOT NULL,
                        created_by TEXT NOT NULL
                    )
                    """
                )
                connection.commit()
            finally:
                connection.close()

            with mock.patch.multiple(
                backend,
                DB_PATH=database,
                STORAGE_ROOT=root / "storage",
                PRIMARY_ADMIN_EMAIL=self.admin_email,
            ):
                backend.initialize_database()
                with backend.db() as migrated:
                    columns = {
                        row["name"]: row for row in migrated.execute("PRAGMA table_info(customer_portal_links)")
                    }
            self.assertIn("opened_count", columns)
            self.assertEqual(columns["opened_count"]["dflt_value"], "0")
            self.assertIn("last_opened_at", columns)


if __name__ == "__main__":
    unittest.main()
