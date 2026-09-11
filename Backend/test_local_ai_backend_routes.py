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
from Backend import gunnaire_local_ai_backend as local_backend
from Backend import local_ai_gateway as gateway


class FakeGateway:
    def __init__(self, *, error: Exception | None = None):
        self.error = error
        self.calls: list[tuple[dict, str]] = []

    def status(self):
        return {
            "enabled": True,
            "available": True,
            "status": "ready",
            "provider": "ollama",
            "local": True,
            "endpointScope": "loopback",
            "hostedFallbackEnabled": False,
            "hostedCreditsUsed": 0,
            "stableDiffusionScope": "image-only",
            "supportedTasks": ["operations_narrative"],
        }

    def assist(self, payload, *, actor_role):
        self.calls.append((dict(payload), actor_role))
        if self.error:
            raise self.error
        return {
            "requestID": "local-ai-request-1",
            "generatedAt": "2026-09-11T02:00:00Z",
            "task": payload["task"],
            "provider": "ollama",
            "model": "devstral-small-2:24b",
            "local": True,
            "cached": False,
            "advisoryOnly": True,
            "hostedFallbackUsed": False,
            "hostedCreditsUsed": 0,
            "stableDiffusionUsed": False,
            "needsHumanApproval": True,
            "redactions": 0,
            "inputDigest": "abc123",
            "metrics": {},
            "result": {
                "headline": "Review dispatch pressure",
                "summary": "Deterministic score retained.",
                "priorities": [],
                "warnings": [],
            },
        }


class LocalAIBackendRouteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.patch = mock.patch.multiple(
            backend,
            DATA_ROOT=root,
            DB_PATH=root / "gunnaire_backend.sqlite3",
            STORAGE_ROOT=root / "storage",
            AUTH_MODE="api-token",
            API_TOKEN="local-ai-test-token",
        )
        self.patch.start()
        backend.initialize_database()
        self.fake = FakeGateway()
        local_backend._GATEWAY = self.fake
        local_backend._GATEWAY_FAILURE = None
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), local_backend.GunnAireLocalAIBackendHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        local_backend.reset_gateway_for_tests()
        self.patch.stop()
        self.temporary.cleanup()

    def request(self, path, *, method="GET", body=None, authorized=True, content_type="application/json"):
        headers = {}
        if authorized:
            headers["Authorization"] = "Bearer local-ai-test-token"
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8") if not isinstance(body, bytes) else body
            headers["Content-Type"] = content_type
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        return urllib.request.urlopen(request, timeout=5)

    def test_status_requires_authentication(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request(local_backend.STATUS_PATH, authorized=False)
        self.assertEqual(caught.exception.code, 401)

    def test_status_reports_local_only_without_hosted_fallback(self):
        with self.request(local_backend.STATUS_PATH) as response:
            payload = json.loads(response.read().decode("utf-8"))
        self.assertEqual(response.status, 200)
        self.assertTrue(payload["local"])
        self.assertFalse(payload["hostedFallbackEnabled"])
        self.assertEqual(payload["hostedCreditsUsed"], 0)
        self.assertEqual(payload["stableDiffusionScope"], "image-only")
        self.assertEqual(payload["serviceVersion"], backend.SERVICE_VERSION)

    def test_assist_uses_authenticated_business_role_and_records_audit(self):
        request_body = {
            "task": "operations_narrative",
            "input": "Summarize the verified snapshot.",
            "context": {"score": 87},
        }
        with self.request(local_backend.ASSIST_PATH, method="POST", body=request_body) as response:
            payload = json.loads(response.read().decode("utf-8"))
        self.assertEqual(response.status, 200)
        self.assertEqual(self.fake.calls, [(request_body, "Admin")])
        self.assertEqual(payload["provider"], "ollama")
        self.assertEqual(payload["hostedCreditsUsed"], 0)
        with backend.db() as connection:
            row = connection.execute(
                "SELECT action, subject_type, subject_id FROM audit_events ORDER BY occurred_at DESC LIMIT 1"
            ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row["action"], "generate-draft")
        self.assertEqual(row["subject_type"], "local-ai-operations_narrative")
        self.assertEqual(row["subject_id"], "local-ai-request-1")

    def test_assist_rejects_non_json_content_type(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request(
                local_backend.ASSIST_PATH,
                method="POST",
                body=b"not-json",
                content_type="text/plain",
            )
        self.assertEqual(caught.exception.code, 415)
        self.assertEqual(self.fake.calls, [])

    def test_assist_maps_policy_error_without_hosted_fallback(self):
        self.fake.error = gateway.InvalidRequest("prohibited_sensitive_data", "Sensitive data rejected")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request(
                local_backend.ASSIST_PATH,
                method="POST",
                body={"task": "operations_narrative", "input": "bad"},
            )
        self.assertEqual(caught.exception.code, 400)
        payload = json.loads(caught.exception.read().decode("utf-8"))
        self.assertEqual(payload["code"], "prohibited_sensitive_data")
        self.assertEqual(payload["hostedCreditsUsed"], 0)
        self.assertFalse(payload["stableDiffusionUsed"])

    def test_assist_maps_local_unavailable_to_503(self):
        self.fake.error = gateway.Unavailable("local_ai_unavailable", "Local model unavailable")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request(
                local_backend.ASSIST_PATH,
                method="POST",
                body={"task": "operations_narrative", "input": "summary"},
            )
        self.assertEqual(caught.exception.code, 503)
        payload = json.loads(caught.exception.read().decode("utf-8"))
        self.assertEqual(payload["code"], "local_ai_unavailable")
        self.assertFalse(payload["hostedFallbackUsed"])

    def test_non_ai_routes_delegate_to_canonical_handler(self):
        with self.request("/health", authorized=False) as response:
            payload = json.loads(response.read().decode("utf-8"))
        self.assertEqual(response.status, 200)
        self.assertEqual(payload["status"], "ok")


if __name__ == "__main__":
    unittest.main()
