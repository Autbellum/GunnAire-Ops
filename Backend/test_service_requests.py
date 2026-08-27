from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from Backend import gunnaire_backend as backend


class ServiceRequestTests(unittest.TestCase):
    api_token = "service-request-test-token"
    admin_email = "admin@gunnaire.com"

    def test_public_booking_is_attributed_and_claimed_by_authenticated_dispatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.multiple(
                backend,
                DB_PATH=root / "gunnaire_backend.sqlite3",
                STORAGE_ROOT=root / "storage",
                AUTH_MODE="api-token",
                API_TOKEN=self.api_token,
                PRIMARY_ADMIN_EMAIL=self.admin_email,
                PUBLIC_BOOKING_ENABLED=True,
                PUBLIC_BOOKING_ATTEMPTS={},
            ):
                backend.initialize_database()
                server = ThreadingHTTPServer(("127.0.0.1", 0), backend.GunnAireBackendHandler)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                base_url = f"http://127.0.0.1:{server.server_port}"
                try:
                    booking = urllib.request.Request(
                        f"{base_url}/api/public/service-requests",
                        data=json.dumps(
                            {
                                "customerName": "Website Lead",
                                "phone": "555-0100",
                                "summary": "Heat pump is not heating",
                                "requestedServiceType": "service",
                                "urgency": "priority",
                                "contactConsent": True,
                            }
                        ).encode("utf-8"),
                        method="POST",
                        headers={"Content-Type": "application/json"},
                    )
                    with urllib.request.urlopen(booking, timeout=5) as response:
                        accepted = json.loads(response.read().decode("utf-8"))
                    self.assertEqual(response.status, 202)

                    auth_headers = {"Authorization": f"Bearer {self.api_token}"}
                    with urllib.request.urlopen(
                        urllib.request.Request(f"{base_url}/api/service-requests", headers=auth_headers),
                        timeout=5,
                    ) as response:
                        requests = json.loads(response.read().decode("utf-8"))["serviceRequests"]
                    self.assertEqual(len(requests), 1)
                    self.assertEqual(requests[0]["id"], accepted["requestID"])
                    self.assertEqual(requests[0]["source"], "website")

                    claim = urllib.request.Request(
                        f"{base_url}/api/service-requests/{accepted['requestID']}/claim",
                        data=b"{}",
                        method="POST",
                        headers={**auth_headers, "Content-Type": "application/json"},
                    )
                    with urllib.request.urlopen(claim, timeout=5) as response:
                        claimed = json.loads(response.read().decode("utf-8"))
                    self.assertTrue(claimed["claimed"])

                    with urllib.request.urlopen(
                        urllib.request.Request(f"{base_url}/api/service-requests", headers=auth_headers),
                        timeout=5,
                    ) as response:
                        remaining = json.loads(response.read().decode("utf-8"))["serviceRequests"]
                    self.assertEqual(remaining, [])

                    with backend.db() as connection:
                        row = connection.execute(
                            "SELECT claimed_by FROM public_service_requests WHERE id = ?",
                            (accepted["requestID"],),
                        ).fetchone()
                    self.assertEqual(row["claimed_by"], self.admin_email)
                finally:
                    server.shutdown()
                    server.server_close()
                    thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
