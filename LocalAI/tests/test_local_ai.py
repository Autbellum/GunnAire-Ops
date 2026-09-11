from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

LOCAL_AI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOCAL_AI))
import local_ai


class LocalAITests(unittest.TestCase):
    def setUp(self):
        self.policy = local_ai.load_policy(LOCAL_AI / "config" / "policy.json")

    def test_loopback_is_accepted(self):
        for endpoint in ("http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"):
            local_ai.ensure_loopback_endpoint(endpoint)

    def test_non_loopback_and_https_are_rejected(self):
        for endpoint in ("http://192.168.4.27:11434", "https://127.0.0.1:11434"):
            with self.assertRaises(local_ai.PolicyError):
                local_ai.ensure_loopback_endpoint(endpoint)

    def test_redaction(self):
        source = "Bearer abcdefghijklmnopqrstuvwxyz refresh_token=super-secret eric@example.com 336-555-1212 4111 1111 1111 1111 123-45-6789"
        result = local_ai.redact_text(source)
        self.assertGreaterEqual(result.replacements, 6)
        self.assertNotIn("super-secret", result.text)
        self.assertNotIn("eric@example.com", result.text)
        self.assertEqual(len(result.sha256), 64)

    def test_private_key_redaction(self):
        result = local_ai.redact_text("-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----")
        self.assertNotIn("\nsecret\n", result.text)

    def test_truncate_middle(self):
        bounded = local_ai.truncate_middle("A" * 100 + "B" * 100, 80)
        self.assertLessEqual(len(bounded), 80)
        self.assertTrue(bounded.startswith("A") and bounded.endswith("B"))
        self.assertIn("TRUNCATED", bounded)

    def test_path_guard(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            good = root / "notes.txt"
            good.write_text("ok")
            self.assertEqual(local_ai.validate_readable_path(good, root, self.policy), good.resolve())
            denied = root / "certificate.p12"
            denied.write_text("synthetic")
            with self.assertRaises(local_ai.PolicyError):
                local_ai.validate_readable_path(denied, root, self.policy)

    def test_path_cannot_escape_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root.parent / "outside-local-ai-test.txt"
            outside.write_text("no")
            try:
                with self.assertRaises(local_ai.PolicyError):
                    local_ai.validate_readable_path(outside, root, self.policy)
            finally:
                outside.unlink(missing_ok=True)

    def test_environment_scrubbing(self):
        clean = local_ai.scrub_environment({"PATH": "/bin", "STRIPE_API_KEY": "x", "QUICKBOOKS_CLIENT_SECRET": "y"}, self.policy)
        self.assertIn("PATH", clean)
        self.assertNotIn("STRIPE_API_KEY", clean)
        self.assertNotIn("QUICKBOOKS_CLIENT_SECRET", clean)
        self.assertEqual(clean["GUNNAIRE_PROVIDER_WRITES_DISABLED"], "1")

    def test_json_parsing(self):
        self.assertEqual(local_ai.parse_json_object('```json\n{"risk":"low"}\n```')["risk"], "low")
        with self.assertRaises(local_ai.OllamaError):
            local_ai.parse_json_object("not json")

    def test_model_matching(self):
        self.assertTrue(local_ai.model_name_matches("gpt-oss:20b", "gpt-oss:20b"))
        self.assertTrue(local_ai.model_name_matches("devstral-small-2:latest", "devstral-small-2"))
        self.assertFalse(local_ai.model_name_matches("gpt-oss:120b", "gpt-oss:20b"))

    def test_high_risk_forces_approval(self):
        config = local_ai.load_config(LOCAL_AI / "config" / "models.json")
        class Client:
            def chat(self, **kwargs):
                return {"summary": "reviewed", "findings": [], "risk": "high", "needs_human_approval": False}, {"model": kwargs["model"], "elapsed_seconds": 0.1}
        result = local_ai.advisory_request(role="reviewer", prompt="Review firewall", domain="firewall", config=config, policy=self.policy, client=Client())
        self.assertTrue(result["needs_human_approval"])
        self.assertTrue(result["_local_ai_metadata"]["advisory_only"])

    def test_client_parses_response(self):
        payload = {"model": "devstral-small-2:24b", "message": {"content": '{"summary":"ok","risk":"low"}'}, "eval_count": 10}
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self): return json.dumps(payload).encode()
        with mock.patch("urllib.request.urlopen", return_value=Response()):
            result, metrics = local_ai.OllamaClient("http://127.0.0.1:11434").chat(model="devstral-small-2:24b", system="s", prompt="p", options={})
        self.assertEqual(result["summary"], "ok")
        self.assertEqual(metrics["eval_count"], 10)


if __name__ == "__main__":
    unittest.main()
