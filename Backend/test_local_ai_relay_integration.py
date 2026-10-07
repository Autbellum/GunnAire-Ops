"""Synthetic HTTP/session/relay/worker integration; no live model or business service."""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from unittest import mock

from Backend import gunnaire_backend as backend
from Backend import gunnaire_local_ai_backend as routes
from Backend.local_ai_relay import LocalAIRelay, RelaySettings
from Backend.test_local_ai_relay_routes import LocalAIRelayRouteTests
from LocalAI import outbound_worker as worker


class IntegrationModel:
    def __init__(self):
        self.deadline = None
        self.calls = 0
        self.after = lambda: None

    def ready(self):
        return None

    def tags(self):
        return [worker.MODEL]

    def chat(self, **kwargs):
        self.calls += 1
        self.after()
        return {"headline": "Fixture dispatch", "summary": "Synthetic facts only.",
                "priorities": [], "warnings": []}, {"model": worker.MODEL}


class LocalAIWorkerIntegrationTests(LocalAIRelayRouteTests):
    # Reuse fixture setup/request helpers without duplicating inherited route cases.
    def setUp(self):
        super().setUp()
        self.kind_patch.stop()
        self.kind_patch = mock.patch.object(routes, "is_relay", side_effect=lambda value: isinstance(value, LocalAIRelay))
        self.kind_patch.start()
        self.relay = LocalAIRelay(RelaySettings(routes.company_identity(), "mac-fixture", self.worker_token, worker.DIGEST))
        self.gateway_patch.stop()
        self.gateway_patch = mock.patch.object(routes, "get_gateway", return_value=self.relay)
        self.gateway_patch.start()
        self.config = worker.WorkerConfig(self.base, self.relay.settings.company_id, "mac-fixture",
            Path(self.temp.name) / "unused-token-reference", Path(self.temp.name) / "claims", Path(self.temp.name) / ".lock")
        Path(self.temp.name).chmod(0o700)
        self.model = IntegrationModel()
        self.worker = worker.Worker(self.config,
            worker.JSONClient(self.base, token=self.worker_token, allow_fixture=True), self.model,
            check_resources=lambda _: None)

    def tearDown(self):
        self.relay.close()
        super().tearDown()

    def drive(self):
        self.assertEqual(self.worker.once(), "idle")
        with ThreadPoolExecutor(max_workers=1) as pool:
            response = pool.submit(self.request, routes.ASSIST_PATH, self.body, token=self.session_token)
            deadline = time.monotonic() + 10
            status = "idle"
            while status == "idle" and time.monotonic() < deadline:
                status = self.worker.once()
                if status == "idle":
                    time.sleep(0.02)
            return status, response.result(timeout=10)

    def test_http_session_to_worker_to_validated_app_response(self):
        state, (status, body) = self.drive()
        self.assertEqual(state, "completed")
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["summary"], "Synthetic facts only.")
        self.assertEqual(self.model.calls, 1)
        self.assertFalse(body["cached"])
        self.assertTrue(body["needsHumanApproval"])
        self.assertFalse(self.relay._jobs)
        self.assertNotIn("Synthetic", self.config.ledger_file.read_text())

    def test_revocation_during_inference_prevents_release_over_real_http(self):
        self.model.after = lambda: self.change("UPDATE auth_sessions SET revoked_at=? WHERE id=?",
            (datetime.now(timezone.utc).isoformat(), self.session_id))
        state, (status, body) = self.drive()
        self.assertEqual(state, "completion_uncertain")
        self.assertEqual(status, 403)
        self.assertNotIn("result", body)
        self.assertEqual(self.model.calls, 1)
        self.assertFalse(self.relay._jobs)


# Only this class's two integration cases run here; the parent suite is separately selected.
def load_tests(loader, tests, pattern):
    suite = unittest.TestSuite()
    for name in ("test_http_session_to_worker_to_validated_app_response",
                 "test_revocation_during_inference_prevents_release_over_real_http"):
        suite.addTest(LocalAIWorkerIntegrationTests(name))
    return suite


if __name__ == "__main__":
    unittest.main()
