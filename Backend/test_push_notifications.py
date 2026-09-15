from __future__ import annotations

import base64
import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from Backend import gunnaire_backend as backend


class StaffPushNotificationTests(unittest.TestCase):
    topic = "com.gunnaire.businesssuite"

    def configured_backend(self, root: Path, *, auth_mode: str = "google-id-token", api_token: str = ""):
        private_key = ec.generate_private_key(ec.SECP256R1()).private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        return mock.patch.multiple(
            backend,
            DB_PATH=root / "gunnaire_backend.sqlite3",
            STORAGE_ROOT=root / "storage",
            AUTH_MODE=auth_mode,
            API_TOKEN=api_token,
            APPLE_CLIENT_ID=self.topic,
            PUSH_TOKEN_ENCRYPTION_KEY=Fernet.generate_key().decode("ascii"),
            APNS_TEAM_ID="7C4B3RR7RD",
            APNS_KEY_ID="A1B2C3D4E5",
            APNS_PRIVATE_KEY_BASE64=base64.b64encode(private_key).decode("ascii"),
            APNS_TOPIC=self.topic,
        )

    def seed_session(self, email: str, role: str) -> str:
        now = datetime.now(timezone.utc)
        token = f"session-{uuid.uuid4()}-{uuid.uuid4()}"
        with backend.db() as connection:
            connection.execute(
                """
                INSERT INTO users(email, role, is_active, created_at, updated_at)
                VALUES (?, ?, 1, ?, ?)
                ON CONFLICT(email) DO UPDATE SET role = excluded.role, is_active = 1
                """,
                (email, role, now.isoformat(), now.isoformat()),
            )
            connection.execute(
                """
                INSERT INTO auth_sessions(
                    id, token_hash, email, provider, provider_subject,
                    created_at, expires_at, last_used_at, revoked_at
                ) VALUES (?, ?, ?, 'apple', ?, ?, ?, ?, NULL)
                """,
                (
                    str(uuid.uuid4()),
                    backend.app_session_token_hash(token),
                    email,
                    f"subject-{email}",
                    now.isoformat(),
                    (now + timedelta(days=1)).isoformat(),
                    now.isoformat(),
                ),
            )
        return token

    @staticmethod
    def request(
        url: str,
        token: str,
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
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
        )

    @staticmethod
    def start_server() -> tuple[ThreadingHTTPServer, threading.Thread, str]:
        server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        return server, thread, f"http://127.0.0.1:{server.server_port}"

    def test_registration_is_session_bound_encrypted_and_assignment_delivery_is_private(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root):
                backend.initialize_database()
                technician_email = "tech@gunnaire.com"
                dispatcher_email = "dispatch@gunnaire.com"
                technician_token = self.seed_session(technician_email, "Field Technician")
                dispatcher_token = self.seed_session(dispatcher_email, "Dispatcher")
                installation_id = str(uuid.uuid4())
                device_token = "ab" * 32
                invoice_id = str(uuid.uuid4())
                server, thread, base_url = self.start_server()
                try:
                    registration = {
                        "installationID": installation_id,
                        "deviceToken": device_token,
                        "platform": "iOS",
                        "environment": "development",
                        "bundleID": self.topic,
                        "appVersion": "1.0",
                        "appBuild": "2026082811",
                    }
                    with urllib.request.urlopen(
                        self.request(
                            f"{base_url}/api/push-devices",
                            technician_token,
                            method="POST",
                            payload=registration,
                        ),
                        timeout=5,
                    ) as response:
                        registered = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, HTTPStatus.CREATED)
                    self.assertTrue(registered["registered"])
                    self.assertNotIn("deviceToken", registered["device"])
                    self.assertNotIn("tokenFingerprint", registered["device"])

                    encoded_installation = urllib.parse.quote(installation_id, safe="")
                    with urllib.request.urlopen(
                        self.request(
                            f"{base_url}/api/push-devices/current?installationID={encoded_installation}",
                            technician_token,
                        ),
                        timeout=5,
                    ) as response:
                        current = json.loads(response.read().decode("utf-8"))
                    self.assertTrue(current["registered"])

                    with backend.db() as connection:
                        stored_device = connection.execute("SELECT * FROM push_devices").fetchone()
                    self.assertNotEqual(stored_device["token_ciphertext"], device_token)
                    self.assertEqual(
                        backend.decrypt_push_device_token(stored_device["token_ciphertext"]),
                        device_token,
                    )

                    assignment_payload = {
                        "invoiceID": invoice_id,
                        "customerName": "Private Customer Name",
                        "amount": 412.75,
                        "assignedTo": technician_email,
                    }
                    with urllib.request.urlopen(
                        self.request(
                            f"{base_url}/api/field-payment-assignments",
                            dispatcher_token,
                            method="POST",
                            payload=assignment_payload,
                        ),
                        timeout=5,
                    ) as response:
                        assignment = json.loads(response.read().decode("utf-8"))["assignment"]
                    self.assertEqual(response.status, HTTPStatus.CREATED)

                    # Replaying the authoritative assignment must not duplicate its alert.
                    with urllib.request.urlopen(
                        self.request(
                            f"{base_url}/api/field-payment-assignments",
                            dispatcher_token,
                            method="POST",
                            payload=assignment_payload,
                        ),
                        timeout=5,
                    ) as response:
                        replay = json.loads(response.read().decode("utf-8"))
                    self.assertTrue(replay["idempotentReplay"])
                    with backend.db() as connection:
                        delivery_count = connection.execute("SELECT COUNT(*) FROM push_deliveries").fetchone()[0]
                    self.assertEqual(delivery_count, 1)

                    captured: list[dict[str, object]] = []

                    def successful_sender(**kwargs: object) -> tuple[int, str | None, str | None]:
                        captured.append(kwargs)
                        return HTTPStatus.OK, None, str(uuid.uuid4())

                    self.assertEqual(backend.deliver_pending_pushes(sender=successful_sender), 1)
                    self.assertEqual(captured[0]["device_token"], device_token)
                    payload = captured[0]["payload"]
                    self.assertEqual(payload["gunnaire"]["route"], "paymentCollection")
                    self.assertEqual(payload["gunnaire"]["recordID"], invoice_id)
                    serialized_payload = json.dumps(payload).lower()
                    for forbidden in ("private customer name", "412.75", "customer", "address", "balance"):
                        self.assertNotIn(forbidden, serialized_payload)
                    self.assertIn("assigned invoice", serialized_payload)

                    # A second pending event is suppressed immediately when this
                    # application session signs out.
                    self.assertEqual(
                        backend.queue_staff_push_event(
                            event_key=f"field-payment-assignment:{uuid.uuid4()}",
                            recipient_email=technician_email,
                            category="field-payment-assignment",
                            route="paymentCollection",
                            record_id=str(uuid.uuid4()),
                        ),
                        1,
                    )
                    with urllib.request.urlopen(
                        self.request(f"{base_url}/api/auth/logout", technician_token, method="POST"),
                        timeout=5,
                    ) as response:
                        self.assertTrue(json.loads(response.read().decode("utf-8"))["revoked"])
                    with backend.db() as connection:
                        device = connection.execute("SELECT * FROM push_devices").fetchone()
                        statuses = [
                            row[0]
                            for row in connection.execute(
                                "SELECT status FROM push_deliveries ORDER BY created_at"
                            ).fetchall()
                        ]
                    self.assertIsNotNone(device["deactivated_at"])
                    self.assertEqual(statuses, ["sent", "suppressed"])
                    self.assertEqual(assignment["assignedTo"], technician_email)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_permanent_apns_rejection_deactivates_device_and_suppresses_queue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root):
                backend.initialize_database()
                email = "field@gunnaire.com"
                token = self.seed_session(email, "Field Technician")
                installation_id = str(uuid.uuid4())
                server, thread, base_url = self.start_server()
                try:
                    with urllib.request.urlopen(
                        self.request(
                            f"{base_url}/api/push-devices",
                            token,
                            method="POST",
                            payload={
                                "installationID": installation_id,
                                "deviceToken": "cd" * 32,
                                "platform": "iOS",
                                "environment": "production",
                                "bundleID": self.topic,
                                "appVersion": "1.0",
                                "appBuild": "1",
                            },
                        ),
                        timeout=5,
                    ):
                        pass
                    for _ in range(2):
                        backend.queue_staff_push_event(
                            event_key=f"field-payment-assignment:{uuid.uuid4()}",
                            recipient_email=email,
                            category="field-payment-assignment",
                            route="paymentCollection",
                            record_id=str(uuid.uuid4()),
                        )

                    def unregistered_sender(**_: object) -> tuple[int, str | None, str | None]:
                        return HTTPStatus.GONE, "Unregistered", None

                    self.assertEqual(backend.deliver_pending_pushes(sender=unregistered_sender, limit=1), 1)
                    with backend.db() as connection:
                        device = connection.execute("SELECT * FROM push_devices").fetchone()
                        statuses = sorted(
                            row[0] for row in connection.execute("SELECT status FROM push_deliveries").fetchall()
                        )
                    self.assertIsNotNone(device["deactivated_at"])
                    self.assertEqual(statuses, ["failed", "suppressed"])
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_own_phone_send_skips_the_origin_device_and_needs_a_collector_role(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.configured_backend(root):
                backend.initialize_database()
                technician_email = "tech@gunnaire.com"
                technician_token = self.seed_session(technician_email, "Field Technician")
                accounting_token = self.seed_session("books@gunnaire.com", "Accounting")
                self.seed_session("tech-b@gunnaire.com", "Field Technician")
                tablet_installation = str(uuid.uuid4())
                phone_installation = str(uuid.uuid4())
                server, thread, base_url = self.start_server()
                try:
                    for installation_id, token_hex in ((tablet_installation, "ab" * 32), (phone_installation, "cd" * 32)):
                        with urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/push-devices",
                                technician_token,
                                method="POST",
                                payload={
                                    "installationID": installation_id,
                                    "deviceToken": token_hex,
                                    "platform": "iOS",
                                    "environment": "development",
                                    "bundleID": self.topic,
                                    "appVersion": "1.0",
                                    "appBuild": "2026091601",
                                },
                            ),
                            timeout=5,
                        ) as response:
                            self.assertEqual(response.status, HTTPStatus.CREATED)

                    # "Send to My iPhone" from the tablet alerts only the other device.
                    invoice_id = str(uuid.uuid4())
                    own_phone = {
                        "invoiceID": invoice_id,
                        "customerName": "Own Phone Customer",
                        "amount": 189,
                        "assignedTo": technician_email,
                        "originInstallationID": tablet_installation,
                    }
                    with urllib.request.urlopen(
                        self.request(f"{base_url}/api/field-payment-assignments", technician_token, method="POST", payload=own_phone),
                        timeout=5,
                    ) as response:
                        assignment = json.loads(response.read().decode("utf-8"))["assignment"]
                    self.assertEqual(response.status, HTTPStatus.CREATED)
                    self.assertEqual(assignment["assignedBy"], technician_email)
                    with backend.db() as connection:
                        alerted = connection.execute(
                            """
                            SELECT push_devices.installation_id
                            FROM push_deliveries
                            INNER JOIN push_devices ON push_devices.id = push_deliveries.device_id
                            WHERE push_deliveries.record_id = ?
                            """,
                            (invoice_id,),
                        ).fetchall()
                    self.assertEqual([row["installation_id"] for row in alerted], [phone_installation])

                    # A field technician still cannot assign anyone else.
                    with self.assertRaises(urllib.error.HTTPError) as forbidden:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/field-payment-assignments",
                                technician_token,
                                method="POST",
                                payload={**own_phone, "invoiceID": str(uuid.uuid4()), "assignedTo": "tech-b@gunnaire.com"},
                            ),
                            timeout=5,
                        )
                    self.assertEqual(forbidden.exception.code, HTTPStatus.FORBIDDEN)

                    # Accounting reviews but does not collect, so it has no own-phone task.
                    with self.assertRaises(urllib.error.HTTPError) as rejected:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/field-payment-assignments",
                                accounting_token,
                                method="POST",
                                payload={**own_phone, "invoiceID": str(uuid.uuid4()), "assignedTo": "books@gunnaire.com"},
                            ),
                            timeout=5,
                        )
                    self.assertEqual(rejected.exception.code, HTTPStatus.BAD_REQUEST)

                    # An office assignment to a technician still alerts every device.
                    office_invoice = str(uuid.uuid4())
                    with urllib.request.urlopen(
                        self.request(
                            f"{base_url}/api/field-payment-assignments",
                            accounting_token,
                            method="POST",
                            payload={"invoiceID": office_invoice, "customerName": "Office Customer", "amount": 75, "assignedTo": technician_email},
                        ),
                        timeout=5,
                    ) as response:
                        self.assertEqual(response.status, HTTPStatus.CREATED)
                    with backend.db() as connection:
                        office_alerts = connection.execute(
                            "SELECT COUNT(*) FROM push_deliveries WHERE record_id = ?", (office_invoice,)
                        ).fetchone()[0]
                        office_assignment_id = connection.execute(
                            "SELECT id FROM field_payment_assignments WHERE invoice_id = ?", (office_invoice,)
                        ).fetchone()["id"]
                    self.assertEqual(office_alerts, 2)

                    # The collector may withdraw the task they sent to their own
                    # phone, but not one the office assigned to them.
                    with self.assertRaises(urllib.error.HTTPError) as office_task:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/field-payment-assignments/{office_assignment_id}",
                                technician_token,
                                method="DELETE",
                            ),
                            timeout=5,
                        )
                    self.assertEqual(office_task.exception.code, HTTPStatus.FORBIDDEN)
                    with urllib.request.urlopen(
                        self.request(
                            f"{base_url}/api/field-payment-assignments/{assignment['id']}",
                            technician_token,
                            method="DELETE",
                        ),
                        timeout=5,
                    ) as response:
                        withdrawn = json.loads(response.read().decode("utf-8"))["assignment"]
                    self.assertEqual(withdrawn["status"], "cancelled")
                    self.assertEqual(withdrawn["id"], assignment["id"])
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_shared_api_token_cannot_create_account_bound_push_registration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            api_token = "development-only-shared-token"
            with self.configured_backend(root, auth_mode="api-token", api_token=api_token):
                backend.initialize_database()
                server, thread, base_url = self.start_server()
                try:
                    with self.assertRaises(urllib.error.HTTPError) as rejected:
                        urllib.request.urlopen(
                            self.request(
                                f"{base_url}/api/push-devices",
                                api_token,
                                method="POST",
                                payload={
                                    "installationID": str(uuid.uuid4()),
                                    "deviceToken": "ef" * 32,
                                    "platform": "iOS",
                                    "environment": "development",
                                    "bundleID": self.topic,
                                    "appVersion": "1.0",
                                    "appBuild": "1",
                                },
                            ),
                            timeout=5,
                        )
                    self.assertEqual(rejected.exception.code, HTTPStatus.FORBIDDEN)
                    with backend.db() as connection:
                        self.assertEqual(connection.execute("SELECT COUNT(*) FROM push_devices").fetchone()[0], 0)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
