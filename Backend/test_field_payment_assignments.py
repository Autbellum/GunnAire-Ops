from __future__ import annotations

import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from Backend import gunnaire_backend as backend


class FieldPaymentAssignmentTests(unittest.TestCase):
    api_token = "field-payment-test-token"
    admin_email = "admin@gunnaire.com"

    def request(
        self,
        url: str,
        *,
        method: str = "GET",
        payload: dict[str, object] | None = None,
    ) -> urllib.request.Request:
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        return urllib.request.Request(
            url,
            data=body,
            method=method,
            headers={
                "Authorization": f"Bearer {self.api_token}",
                "Content-Type": "application/json",
            },
        )

    def test_unique_assignment_partial_completion_and_authenticated_collector(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                AUTH_MODE="api-token",
                API_TOKEN=self.api_token,
                PRIMARY_ADMIN_EMAIL=self.admin_email,
            ):
                backend.initialize_database()
                now = backend.utc_now()
                with backend.db() as connection:
                    for email in ("tech-a@gunnaire.com", "tech-b@gunnaire.com"):
                        connection.execute(
                            """
                            INSERT INTO users(email, role, is_active, created_at, updated_at)
                            VALUES (?, 'Field Technician', 1, ?, ?)
                            """,
                            (email, now, now),
                        )

                server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                base_url = f"http://127.0.0.1:{server.server_port}"
                invoice_id = str(uuid.uuid4())
                try:
                    assignment_payload = {
                        "invoiceID": invoice_id,
                        "customerName": "Field Customer",
                        "amount": 200,
                        "assignedTo": "tech-a@gunnaire.com",
                    }
                    with urllib.request.urlopen(
                        self.request(f"{base_url}/api/field-payment-assignments", method="POST", payload=assignment_payload),
                        timeout=5,
                    ) as response:
                        assignment = json.loads(response.read().decode("utf-8"))["assignment"]
                    self.assertEqual(response.status, 201)
                    self.assertEqual(assignment["status"], "pending")
                    self.assertEqual(assignment["collectedAmount"], 0)

                    # Retrying the same assignment is idempotent.
                    with urllib.request.urlopen(
                        self.request(f"{base_url}/api/field-payment-assignments", method="POST", payload=assignment_payload),
                        timeout=5,
                    ) as response:
                        replay = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 200)
                    self.assertTrue(replay["idempotentReplay"])

                    conflicting = {**assignment_payload, "assignedTo": "tech-b@gunnaire.com"}
                    with self.assertRaises(urllib.error.HTTPError) as duplicate:
                        urllib.request.urlopen(
                            self.request(f"{base_url}/api/field-payment-assignments", method="POST", payload=conflicting),
                            timeout=5,
                        )
                    self.assertEqual(duplicate.exception.code, 409)

                    first_payment_id = str(uuid.uuid4())
                    first_payment = {
                        "paymentID": first_payment_id,
                        "invoiceID": invoice_id,
                        "customerName": "Field Customer",
                        "amount": 125,
                        "method": "card",
                        "collectedBy": "spoofed@attacker.example",
                        "collectedAt": "2026-08-27T10:00:00+00:00",
                    }
                    with urllib.request.urlopen(
                        self.request(f"{base_url}/api/payments", method="POST", payload=first_payment),
                        timeout=5,
                    ) as response:
                        partial = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(partial["assignmentUpdates"], [{"id": assignment["id"], "status": "accepted"}])

                    # A transport retry must not double-count the same durable payment ID.
                    with urllib.request.urlopen(
                        self.request(f"{base_url}/api/payments", method="POST", payload=first_payment),
                        timeout=5,
                    ) as response:
                        payment_replay = json.loads(response.read().decode("utf-8"))
                    self.assertTrue(payment_replay["idempotentReplay"])

                    with urllib.request.urlopen(
                        self.request(f"{base_url}/api/field-payment-assignments"), timeout=5
                    ) as response:
                        active = json.loads(response.read().decode("utf-8"))["assignments"][0]
                    self.assertEqual(active["status"], "accepted")
                    self.assertEqual(active["collectedAmount"], 125)
                    self.assertIsNone(active["completedBy"])

                    second_payment_id = str(uuid.uuid4())
                    second_payment = {
                        **first_payment,
                        "paymentID": second_payment_id,
                        "amount": 75,
                        "collectedAt": "2026-08-27T10:05:00+00:00",
                    }
                    with urllib.request.urlopen(
                        self.request(f"{base_url}/api/payments", method="POST", payload=second_payment),
                        timeout=5,
                    ) as response:
                        completed = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(completed["assignmentUpdates"], [{"id": assignment["id"], "status": "completed"}])

                    with urllib.request.urlopen(
                        self.request(f"{base_url}/api/field-payment-assignments"), timeout=5
                    ) as response:
                        finished = json.loads(response.read().decode("utf-8"))["assignments"][0]
                    self.assertEqual(finished["status"], "completed")
                    self.assertEqual(finished["collectedAmount"], 200)
                    self.assertEqual(finished["completedBy"], self.admin_email)
                    self.assertEqual(finished["completionPaymentID"], second_payment_id)

                    with backend.db() as connection:
                        collector = connection.execute(
                            "SELECT collected_by FROM payment_collections WHERE payment_id = ?", (first_payment_id,)
                        ).fetchone()["collected_by"]
                    self.assertEqual(collector, self.admin_email)

                    with self.assertRaises(urllib.error.HTTPError) as immutable:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/field-payment-assignments/{assignment['id']}", method="DELETE"
                            ),
                            timeout=5,
                        )
                    self.assertEqual(immutable.exception.code, 409)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_initialize_database_adds_completion_columns_to_existing_assignment_table(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "gunnaire_backend.sqlite3"
            connection = sqlite3.connect(database)
            try:
                connection.execute(
                    """
                    CREATE TABLE field_payment_assignments (
                        id TEXT PRIMARY KEY,
                        invoice_id TEXT NOT NULL,
                        customer_name TEXT NOT NULL,
                        amount REAL NOT NULL,
                        assigned_to TEXT NOT NULL,
                        assigned_by TEXT NOT NULL,
                        status TEXT NOT NULL,
                        created_at TEXT NOT NULL,
                        accepted_at TEXT,
                        cancelled_at TEXT,
                        cancelled_by TEXT
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
                    columns = {row["name"] for row in migrated.execute("PRAGMA table_info(field_payment_assignments)")}

            self.assertTrue(
                {"collected_amount", "completed_at", "completed_by", "completion_payment_id"}.issubset(columns)
            )


if __name__ == "__main__":
    unittest.main()
