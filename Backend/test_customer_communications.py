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


class FieldTechnicianCommunicationHandler(backend.GunnAireBackendHandler):
    def principal(self) -> dict[str, object]:
        return {
            "email": "field.tech@gunnaire.com",
            "role": "Field Technician",
            "isActive": True,
            "createdAt": None,
        }


class CustomerCommunicationTests(unittest.TestCase):
    def test_field_technician_can_store_consent_aware_apple_messages_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), FieldTechnicianCommunicationHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                url = f"http://127.0.0.1:{server.server_port}/api/communications"
                payload = {
                    "id": str(uuid.uuid4()),
                    "customerName": "Service Text Customer",
                    "customerEmail": "customer@example.com",
                    "serviceCallID": str(uuid.uuid4()),
                    "channel": "text",
                    "direction": "outbound",
                    "recipient": "+1 (863) 555-0134",
                    "subject": "On-my-way update",
                    "deliveryStatus": "sent",
                    "workflow": "technicianEnRoute",
                    "templateVersion": "technicianEnRoute-text-v1",
                    "consentSnapshot": {
                        "allowsTransactionalEmail": True,
                        "allowsServiceText": True,
                        "allowsMarketing": False,
                        "preferredContactMethod": "text",
                        "consentUpdatedAt": "2026-08-27T14:00:00Z",
                    },
                    "providerStatusDetail": "Apple Messages composer reported sent.",
                    "deliveredAt": "2026-08-27T14:05:00Z",
                    "attachmentFileNames": [],
                    "providerMessageID": None,
                    "occurredAt": "2026-08-27T14:05:00Z",
                }

                try:
                    request = urllib.request.Request(
                        url,
                        data=json.dumps(payload).encode("utf-8"),
                        method="POST",
                        headers={"Content-Type": "application/json"},
                    )
                    with urllib.request.urlopen(request, timeout=5) as response:
                        created = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 201)
                    self.assertEqual(created["channel"], "text")
                    self.assertEqual(created["recipient"], "+18635550134")
                    self.assertEqual(created["templateVersion"], "technicianEnRoute-text-v1")
                    self.assertTrue(created["consentSnapshot"]["allowsServiceText"])

                    invalid_payload = {
                        **payload,
                        "id": str(uuid.uuid4()),
                        "recipient": "555",
                    }
                    invalid_request = urllib.request.Request(
                        url,
                        data=json.dumps(invalid_payload).encode("utf-8"),
                        method="POST",
                        headers={"Content-Type": "application/json"},
                    )
                    with self.assertRaises(urllib.error.HTTPError) as invalid:
                        urllib.request.urlopen(invalid_request, timeout=5)
                    self.assertEqual(invalid.exception.code, 400)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_field_technician_can_store_typed_immutable_delivery_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), FieldTechnicianCommunicationHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                url = f"http://127.0.0.1:{server.server_port}/api/communications"
                record_id = str(uuid.uuid4())
                service_call_id = str(uuid.uuid4())
                payload = {
                    "id": record_id,
                    "customerName": "Typed Communication Customer",
                    "customerEmail": "customer@example.com",
                    "serviceCallID": service_call_id,
                    "invoiceID": None,
                    "estimateID": None,
                    "maintenanceContractID": None,
                    "channel": "email",
                    "direction": "outbound",
                    "recipient": "customer@example.com",
                    "subject": "Your technician is on the way",
                    "deliveryStatus": "sent",
                    "workflow": "technicianEnRoute",
                    "templateVersion": "technicianEnRoute-v1",
                    "consentSnapshot": {
                        "allowsTransactionalEmail": True,
                        "allowsServiceText": False,
                        "allowsMarketing": False,
                        "preferredContactMethod": "email",
                        "consentUpdatedAt": "2026-08-27T14:00:00Z",
                    },
                    "providerStatusDetail": None,
                    "deliveredAt": "2026-08-27T14:05:00Z",
                    "attachmentFileNames": [],
                    "providerMessageID": "gmail-message-typed-1",
                    "occurredAt": "2026-08-27T14:05:00Z",
                }

                def request(body: dict[str, object]) -> urllib.request.Request:
                    return urllib.request.Request(
                        url,
                        data=json.dumps(body).encode("utf-8"),
                        method="POST",
                        headers={"Content-Type": "application/json"},
                    )

                try:
                    with urllib.request.urlopen(request(payload), timeout=5) as response:
                        created = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 201)
                    self.assertEqual(created["workflow"], "technicianEnRoute")
                    self.assertEqual(created["templateVersion"], "technicianEnRoute-v1")
                    self.assertEqual(created["actorEmail"], "field.tech@gunnaire.com")
                    self.assertEqual(created["serviceCallID"], service_call_id)
                    self.assertTrue(created["consentSnapshot"]["allowsTransactionalEmail"])
                    self.assertIsNotNone(created["deliveredAt"])

                    with urllib.request.urlopen(request(payload), timeout=5) as response:
                        replay = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 200)
                    self.assertEqual(replay["id"], record_id)

                    with self.assertRaises(urllib.error.HTTPError) as conflict:
                        urllib.request.urlopen(request({**payload, "subject": "Different attempt"}), timeout=5)
                    self.assertEqual(conflict.exception.code, 409)

                    with backend.db() as connection:
                        row = connection.execute(
                            "SELECT actor_email, workflow, delivery_status FROM customer_communications WHERE id = ?",
                            (record_id,),
                        ).fetchone()
                    self.assertEqual(row["actor_email"], "field.tech@gunnaire.com")
                    self.assertEqual(row["workflow"], "technicianEnRoute")
                    self.assertEqual(row["delivery_status"], "sent")
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_invalid_workflow_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), FieldTechnicianCommunicationHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    request = urllib.request.Request(
                        f"http://127.0.0.1:{server.server_port}/api/communications",
                        data=json.dumps(
                            {
                                "id": str(uuid.uuid4()),
                                "customerName": "Invalid Workflow Customer",
                                "recipient": "customer@example.com",
                                "subject": "Invalid",
                                "deliveryStatus": "sent",
                                "workflow": "arbitraryMutation",
                                "attachmentFileNames": [],
                            }
                        ).encode("utf-8"),
                        method="POST",
                        headers={"Content-Type": "application/json"},
                    )
                    with self.assertRaises(urllib.error.HTTPError) as invalid:
                        urllib.request.urlopen(request, timeout=5)
                    self.assertEqual(invalid.exception.code, 400)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_initialize_database_adds_communication_lifecycle_columns(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "gunnaire_backend.sqlite3"
            connection = sqlite3.connect(database)
            try:
                connection.execute(
                    """
                    CREATE TABLE customer_communications (
                        id TEXT PRIMARY KEY,
                        customer_name TEXT NOT NULL,
                        customer_email TEXT,
                        service_call_id TEXT,
                        invoice_id TEXT,
                        estimate_id TEXT,
                        channel TEXT NOT NULL,
                        direction TEXT NOT NULL,
                        recipient TEXT NOT NULL,
                        subject TEXT NOT NULL,
                        delivery_status TEXT NOT NULL,
                        attachment_file_names_json TEXT,
                        provider_message_id TEXT,
                        occurred_at TEXT NOT NULL,
                        created_at TEXT NOT NULL
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
            ):
                backend.initialize_database()
                with backend.db() as migrated:
                    columns = {row["name"] for row in migrated.execute("PRAGMA table_info(customer_communications)")}

            self.assertTrue(
                {
                    "maintenance_contract_id",
                    "workflow",
                    "template_version",
                    "actor_email",
                    "consent_snapshot_json",
                    "provider_status_detail",
                    "delivered_at",
                }.issubset(columns)
            )


if __name__ == "__main__":
    unittest.main()
