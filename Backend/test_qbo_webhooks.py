from __future__ import annotations

import base64
import hashlib
import hmac
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


class QuickBooksWebhookTests(unittest.TestCase):
    verifier_token = "intuit-webhook-verifier-token"
    api_token = "admin-api-token"
    realm_id = "9341455327810551"

    def signed_request(self, url: str, events: list[dict[str, object]]) -> urllib.request.Request:
        body = json.dumps(events, separators=(",", ":")).encode("utf-8")
        signature = base64.b64encode(
            hmac.new(self.verifier_token.encode("utf-8"), body, hashlib.sha256).digest()
        ).decode("ascii")
        return urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "intuit-signature": signature,
            },
        )

    def cloud_event(
        self,
        event_id: str,
        entity_type: str = "invoice",
        operation: str = "updated",
        entity_id: str = "42",
        realm_id: str | None = None,
    ) -> dict[str, object]:
        return {
            "specversion": "1.0",
            "id": event_id,
            "source": "intuit.test",
            "type": f"qbo.{entity_type}.{operation}.v1",
            "datacontenttype": "application/json",
            "time": "2026-08-26T22:00:00.000Z",
            "intuitentityid": entity_id,
            "intuitaccountid": realm_id or self.realm_id,
            "data": {"ignored": "customer content is not retained"},
        }

    def test_parser_accepts_current_cloudevents_and_rejects_legacy_payloads(self) -> None:
        raw = json.dumps([self.cloud_event("event-1")]).encode("utf-8")

        records = backend.parse_qbo_cloudevents(raw)

        self.assertEqual(records[0]["entityType"], "invoice")
        self.assertEqual(records[0]["operation"], "updated")
        self.assertNotIn("data", records[0])
        with self.assertRaises(ValueError):
            backend.parse_qbo_cloudevents(json.dumps({"eventNotifications": []}).encode("utf-8"))

    def test_signed_endpoint_deduplicates_binds_realm_and_acknowledges_exact_events(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                AUTH_MODE="api-token",
                API_TOKEN=self.api_token,
                QBO_WEBHOOK_VERIFIER_TOKEN=self.verifier_token,
            ):
                backend.initialize_database()
                with backend.db() as connection:
                    connection.execute(
                        """
                        INSERT INTO qbo_connections(
                            id, realm_id, refresh_token_ciphertext, environment,
                            client_id_fingerprint, authorized_at, updated_at
                        ) VALUES (1, ?, 'ciphertext', 'production', 'fingerprint', 'now', 'now')
                        """,
                        (self.realm_id,),
                    )

                server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                base_url = f"http://127.0.0.1:{server.server_port}"
                try:
                    events = [
                        self.cloud_event("event-1"),
                        self.cloud_event("event-2", entity_type="item", operation="created", entity_id="84"),
                        self.cloud_event("event-other-realm", realm_id="999999"),
                    ]
                    with urllib.request.urlopen(self.signed_request(f"{base_url}/api/qbo/webhooks", events), timeout=5) as response:
                        accepted = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 200)
                    self.assertEqual(accepted["stored"], 2)

                    with urllib.request.urlopen(self.signed_request(f"{base_url}/api/qbo/webhooks", events), timeout=5) as response:
                        duplicate = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(duplicate["stored"], 0)

                    with self.assertRaises(urllib.error.HTTPError) as unauthorized:
                        urllib.request.urlopen(f"{base_url}/api/qbo/webhook-events", timeout=5)
                    self.assertEqual(unauthorized.exception.code, 401)

                    admin_headers = {"Authorization": f"Bearer {self.api_token}"}
                    request = urllib.request.Request(f"{base_url}/api/qbo/webhook-events", headers=admin_headers)
                    with urllib.request.urlopen(request, timeout=5) as response:
                        pending = json.loads(response.read().decode("utf-8"))["events"]
                    self.assertEqual([event["id"] for event in pending], ["event-1", "event-2"])
                    self.assertNotIn("realmID", pending[0])

                    body = json.dumps({"eventIDs": ["event-1"]}).encode("utf-8")
                    acknowledge = urllib.request.Request(
                        f"{base_url}/api/qbo/webhook-events/acknowledge",
                        data=body,
                        method="POST",
                        headers={**admin_headers, "Content-Type": "application/json"},
                    )
                    with urllib.request.urlopen(acknowledge, timeout=5) as response:
                        result = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(result["acknowledged"], 1)

                    with urllib.request.urlopen(request, timeout=5) as response:
                        remaining = json.loads(response.read().decode("utf-8"))["events"]
                    self.assertEqual([event["id"] for event in remaining], ["event-2"])
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)

    def test_invalid_signature_is_rejected_without_storing_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                QBO_WEBHOOK_VERIFIER_TOKEN=self.verifier_token,
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    body = json.dumps([self.cloud_event("forged-event")]).encode("utf-8")
                    request = urllib.request.Request(
                        f"http://127.0.0.1:{server.server_port}/api/qbo/webhooks",
                        data=body,
                        method="POST",
                        headers={"intuit-signature": "not-valid"},
                    )
                    with self.assertRaises(urllib.error.HTTPError) as rejected:
                        urllib.request.urlopen(request, timeout=5)
                    self.assertEqual(rejected.exception.code, 401)
                    with backend.db() as connection:
                        count = connection.execute("SELECT COUNT(*) FROM qbo_webhook_events").fetchone()[0]
                    self.assertEqual(count, 0)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
