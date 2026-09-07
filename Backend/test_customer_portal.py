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
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Iterator
from urllib.parse import urlencode, urlparse
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

    def portal_approval_payload(self) -> dict[str, object]:
        return {
            **self.portal_payload(),
            "estimateID": str(uuid.uuid4()),
            "estimateLabel": "Best <Comfort> Option",
            "estimateAmount": 12_345.678,
            "estimateRevision": "a" * 64,
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

    def submit_approval(self, base_url: str, token: str) -> str:
        request = urllib.request.Request(
            f"{base_url}/portal/{token}/estimate-response",
            data=urlencode({"approvalName": "Alex Customer", "approvalConfirmed": "yes"}).encode(),
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.read().decode()

    @contextmanager
    def pause_database_statement(
        self,
        matches: Callable[[str, tuple], bool],
        *,
        after_read: bool = False,
    ) -> Iterator[tuple[threading.Event, threading.Event]]:
        """Hold one request at a real SQLite boundary while another request commits."""
        paused = threading.Event()
        resume = threading.Event()

        def pause() -> None:
            paused.set()
            if not resume.wait(timeout=10):
                raise TimeoutError("Concurrent portal request did not resume")

        class PausingConnection(sqlite3.Connection):
            def execute(self, sql: str, parameters: tuple = ()):
                should_pause = matches(sql, parameters) and not paused.is_set()
                if should_pause and not after_read:
                    pause()
                cursor = super().execute(sql, parameters)
                if should_pause and after_read:
                    def fetchone():
                        row = cursor.fetchone()
                        pause()
                        return row
                    wrapped = mock.Mock(wraps=cursor)
                    wrapped.fetchone.side_effect = fetchone
                    return wrapped
                return cursor

        def connection() -> sqlite3.Connection:
            result = sqlite3.connect(backend.DB_PATH, factory=PausingConnection)
            result.row_factory = sqlite3.Row
            return result

        with mock.patch.object(backend, "db", side_effect=connection):
            try:
                yield paused, resume
            finally:
                resume.set()

    def test_oversized_portal_amounts_return_validation_errors(self) -> None:
        with self.running_server() as base_url:
            for field in ("balanceDue", "estimateAmount"):
                for amount in (10 ** 400, -(10 ** 400)):
                    with self.subTest(field=field, sign=amount > 0):
                        payload = {**self.portal_approval_payload(), field: amount}
                        with self.assertRaises(urllib.error.HTTPError) as invalid:
                            self.create_link(base_url, payload)
                        self.assertEqual(invalid.exception.code, 400)
            with backend.db() as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM customer_portal_links").fetchone()[0], 0)
            self.create_link(base_url, self.portal_approval_payload())

    def test_stale_resolution_cannot_overwrite_applied_approval(self) -> None:
        with self.running_server() as base_url, ThreadPoolExecutor(max_workers=1) as requests:
            created = self.create_link(base_url, self.portal_approval_payload())
            token = urlparse(str(created["url"])).path.removeprefix("/portal/")
            self.submit_approval(base_url, token)
            link_id = str(created["id"])
            with backend.db() as connection:
                response_id = connection.execute(
                    "SELECT estimate_response_id FROM customer_portal_links WHERE id = ?", (link_id,)
                ).fetchone()[0]

            def resolve(status: str, detail: str) -> dict[str, object]:
                request = self.request(
                    base_url, f"/api/customer-portal-links/{link_id}/estimate-response-resolution",
                    method="POST", payload={"responseID": response_id, "status": status, "detail": detail},
                )
                with urllib.request.urlopen(request, timeout=10) as response:
                    return json.loads(response.read())

            with self.pause_database_statement(
                lambda sql, args: "SET estimate_resolution_status" in sql and args[0] == "needs_attention"
            ) as (paused, resume):
                stale = requests.submit(resolve, "needs_attention", "Stale local estimate")
                self.assertTrue(paused.wait(timeout=5))
                applied = resolve("applied", "Imported exact customer approval")
                resume.set()
                with self.assertRaises(urllib.error.HTTPError) as conflict:
                    stale.result(timeout=10)
                self.assertEqual(conflict.exception.code, 409)

            replayed = resolve("applied", "Later request must preserve original evidence")
            for field in ("estimateResolutionStatus", "estimateResolutionDetail", "estimateResolvedAt", "estimateResolvedBy"):
                self.assertEqual(replayed[field], applied[field])
            with backend.db() as connection:
                actions = connection.execute(
                    "SELECT action FROM audit_events WHERE subject_id = ? AND action LIKE 'estimate-approval-%'",
                    (link_id,),
                ).fetchall()
            self.assertEqual([row[0] for row in actions], ["estimate-approval-applied"])

    def test_revocation_during_approval_or_replay_never_confirms_success(self) -> None:
        with self.running_server() as base_url, ThreadPoolExecutor(max_workers=1) as requests:
            for already_approved in (False, True):
                with self.subTest(already_approved=already_approved):
                    created = self.create_link(base_url, self.portal_approval_payload())
                    link_id = str(created["id"])
                    token = urlparse(str(created["url"])).path.removeprefix("/portal/")
                    if already_approved:
                        self.submit_approval(base_url, token)
                    with self.pause_database_statement(
                        lambda sql, args: "SELECT * FROM customer_portal_links WHERE token_hash" in sql,
                        after_read=True,
                    ) as (paused, resume):
                        pending = requests.submit(self.submit_approval, base_url, token)
                        self.assertTrue(paused.wait(timeout=5))
                        with urllib.request.urlopen(self.request(
                            base_url, f"/api/customer-portal-links/{link_id}", method="DELETE"
                        ), timeout=5) as response:
                            self.assertTrue(json.loads(response.read())["revoked"])
                        resume.set()
                        with self.assertRaises(urllib.error.HTTPError) as unavailable:
                            pending.result(timeout=10)
                        self.assertEqual(unavailable.exception.code, 404)
                    with backend.db() as connection:
                        stored = connection.execute(
                            "SELECT * FROM customer_portal_links WHERE id = ?", (link_id,)
                        ).fetchone()
                    self.assertIsNotNone(stored["revoked_at"])
                    self.assertEqual(stored["estimate_response_id"] is not None, already_approved)

    def test_concurrent_applied_replay_preserves_first_resolution_and_single_audit(self) -> None:
        with self.running_server() as base_url, ThreadPoolExecutor(max_workers=1) as requests:
            created = self.create_link(base_url, self.portal_approval_payload())
            link_id = str(created["id"])
            token = urlparse(str(created["url"])).path.removeprefix("/portal/")
            self.submit_approval(base_url, token)
            with backend.db() as connection:
                response_id = connection.execute(
                    "SELECT estimate_response_id FROM customer_portal_links WHERE id = ?", (link_id,)
                ).fetchone()[0]

            def resolve(detail: str) -> dict[str, object]:
                with urllib.request.urlopen(self.request(
                    base_url, f"/api/customer-portal-links/{link_id}/estimate-response-resolution",
                    method="POST", payload={"responseID": response_id, "status": "applied", "detail": detail},
                ), timeout=10) as response:
                    return json.loads(response.read())

            with self.pause_database_statement(
                lambda sql, args: "SET estimate_resolution_status" in sql and args[1] == "Second import"
            ) as (paused, resume):
                delayed = requests.submit(resolve, "Second import")
                self.assertTrue(paused.wait(timeout=5))
                first = resolve("First import")
                resume.set()
                self.assertEqual(delayed.result(timeout=10), first)
            with backend.db() as connection:
                count = connection.execute(
                    "SELECT COUNT(*) FROM audit_events WHERE subject_id = ? AND action = 'estimate-approval-applied'",
                    (link_id,),
                ).fetchone()[0]
            self.assertEqual(count, 1)

    def test_resolution_and_audit_commit_together(self) -> None:
        with self.running_server() as base_url:
            created = self.create_link(base_url, self.portal_approval_payload())
            link_id = str(created["id"])
            token = urlparse(str(created["url"])).path.removeprefix("/portal/")
            self.submit_approval(base_url, token)
            with backend.db() as connection:
                before = dict(connection.execute(
                    "SELECT * FROM customer_portal_links WHERE id = ?", (link_id,)
                ).fetchone())
            handler = mock.Mock()
            handler.read_json.return_value = {"responseID": before["estimate_response_id"], "status": "applied"}
            handler.principal.return_value = {"email": self.admin_email}
            with mock.patch.object(backend, "record_audit_event", side_effect=RuntimeError("Audit storage failed")):
                with self.assertRaisesRegex(RuntimeError, "Audit storage failed"):
                    backend.GunnAireBackendHandler.resolve_customer_portal_estimate_response(handler, link_id)
            handler.write_json.assert_not_called()
            with backend.db() as connection:
                after = dict(connection.execute(
                    "SELECT * FROM customer_portal_links WHERE id = ?", (link_id,)
                ).fetchone())
            self.assertEqual(after, before)

    def test_expiry_during_approval_does_not_record_customer_consent(self) -> None:
        with self.running_server() as base_url, ThreadPoolExecutor(max_workers=1) as requests:
            created = self.create_link(base_url, self.portal_approval_payload())
            token = urlparse(str(created["url"])).path.removeprefix("/portal/")
            with self.pause_database_statement(
                lambda sql, args: "SELECT * FROM customer_portal_links WHERE token_hash" in sql,
                after_read=True,
            ) as (paused, resume):
                pending = requests.submit(self.submit_approval, base_url, token)
                self.assertTrue(paused.wait(timeout=5))
                with backend.db() as connection:
                    connection.execute(
                        "UPDATE customer_portal_links SET expires_at = ? WHERE id = ?",
                        ((datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat(), created["id"]),
                    )
                resume.set()
                with self.assertRaises(urllib.error.HTTPError) as unavailable:
                    pending.result(timeout=10)
                self.assertEqual(unavailable.exception.code, 404)
            with backend.db() as connection:
                row = connection.execute(
                    "SELECT estimate_response_id FROM customer_portal_links WHERE id = ?", (created["id"],)
                ).fetchone()
            self.assertIsNone(row[0])

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
                {**base, "estimateID": str(uuid.uuid4())},
                {
                    **base,
                    "estimateID": str(uuid.uuid4()),
                    "estimateLabel": "Service estimate",
                    "estimateAmount": 100,
                    "estimateRevision": "not-a-digest",
                },
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

    def test_exact_estimate_approval_is_one_time_and_requires_admin_reconciliation(self) -> None:
        with self.running_server() as base_url:
            created = self.create_link(base_url, self.portal_approval_payload())
            link_id = str(created["id"])
            token = urlparse(str(created["url"])).path.removeprefix("/portal/")

            with urllib.request.urlopen(
                self.request(base_url, f"/portal/{token}", authenticated=False),
                timeout=5,
            ) as response:
                page = response.read().decode("utf-8")
                headers = response.headers
            self.assertIn("Approve this estimate", page)
            self.assertIn("Best &lt;Comfort&gt; Option", page)
            self.assertIn("$12,345.68", page)
            self.assertIn(f'action="/portal/{token}/estimate-response"', page)
            self.assertIn("form-action 'self'", headers["Content-Security-Policy"])

            invalid_form_data = urlencode(
                {"approvalName": "Alex\nCustomer", "approvalConfirmed": "yes"}
            ).encode("utf-8")
            invalid_approval_request = urllib.request.Request(
                f"{base_url}/portal/{token}/estimate-response",
                data=invalid_form_data,
                method="POST",
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            with self.assertRaises(urllib.error.HTTPError) as invalid_name:
                urllib.request.urlopen(invalid_approval_request, timeout=5)
            self.assertEqual(invalid_name.exception.code, 400)

            form_data = urlencode(
                {"approvalName": "Alex <Customer>", "approvalConfirmed": "yes"}
            ).encode("utf-8")
            approval_request = urllib.request.Request(
                f"{base_url}/portal/{token}/estimate-response",
                data=form_data,
                method="POST",
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            with urllib.request.urlopen(approval_request, timeout=5) as response:
                confirmation = response.read().decode("utf-8")
            self.assertEqual(response.status, 200)
            self.assertIn("Estimate approved", confirmation)
            self.assertIn("Alex &lt;Customer&gt;", confirmation)
            self.assertNotIn("Alex <Customer>", confirmation)

            with backend.db() as connection:
                stored = connection.execute(
                    "SELECT * FROM customer_portal_links WHERE id = ?",
                    (link_id,),
                ).fetchone()
            response_id = stored["estimate_response_id"]
            first_response_time = stored["estimate_responded_at"]
            self.assertIsNotNone(response_id)
            self.assertEqual(stored["estimate_response_name"], "Alex <Customer>")
            self.assertEqual(stored["estimate_resolution_status"], "pending")

            replay_data = urlencode(
                {"approvalName": "Changed Name", "approvalConfirmed": "yes"}
            ).encode("utf-8")
            replay_request = urllib.request.Request(
                f"{base_url}/portal/{token}/estimate-response",
                data=replay_data,
                method="POST",
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            with urllib.request.urlopen(replay_request, timeout=5) as response:
                replay_page = response.read().decode("utf-8")
            self.assertIn("Alex &lt;Customer&gt;", replay_page)
            self.assertNotIn("Changed Name", replay_page)
            with backend.db() as connection:
                replayed = connection.execute(
                    "SELECT * FROM customer_portal_links WHERE id = ?",
                    (link_id,),
                ).fetchone()
            self.assertEqual(replayed["estimate_response_id"], response_id)
            self.assertEqual(replayed["estimate_responded_at"], first_response_time)

            resolution = self.request(
                base_url,
                f"/api/customer-portal-links/{link_id}/estimate-response-resolution",
                method="POST",
                payload={"responseID": response_id, "status": "applied"},
            )
            with urllib.request.urlopen(resolution, timeout=5) as response:
                applied = json.loads(response.read().decode("utf-8"))
            self.assertEqual(applied["estimateResolutionStatus"], "applied")
            self.assertEqual(applied["estimateResponseID"], response_id)
            self.assertNotIn("token", applied)
            self.assertNotIn("tokenHash", applied)

            with self.assertRaises(urllib.error.HTTPError) as downgrade:
                urllib.request.urlopen(
                    self.request(
                        base_url,
                        f"/api/customer-portal-links/{link_id}/estimate-response-resolution",
                        method="POST",
                        payload={
                            "responseID": response_id,
                            "status": "needs_attention",
                            "detail": "Do not downgrade applied evidence",
                        },
                    ),
                    timeout=5,
                )
            self.assertEqual(downgrade.exception.code, 409)

            with self.assertRaises(urllib.error.HTTPError) as invalid_link_id:
                urllib.request.urlopen(
                    self.request(
                        base_url,
                        "/api/customer-portal-links/------------------------------------/estimate-response-resolution",
                        method="POST",
                        payload={"responseID": response_id, "status": "applied"},
                    ),
                    timeout=5,
                )
            self.assertEqual(invalid_link_id.exception.code, 400)

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
                self.request(
                    base_url,
                    f"/api/customer-portal-links/{link_id}/estimate-response-resolution",
                    method="POST",
                    payload={
                        "responseID": str(uuid.uuid4()),
                        "status": "needs_attention",
                        "detail": "Restricted",
                    },
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
            for column in (
                "estimate_id", "estimate_label", "estimate_amount", "estimate_revision",
                "estimate_response_id", "estimate_response_name", "estimate_responded_at",
                "estimate_resolution_status", "estimate_resolution_detail",
                "estimate_resolved_at", "estimate_resolved_by",
            ):
                self.assertIn(column, columns)


if __name__ == "__main__":
    unittest.main()
