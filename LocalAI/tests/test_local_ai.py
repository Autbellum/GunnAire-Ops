from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE))
import local_ai


class LocalAITests(unittest.TestCase):
    def setUp(self):
        self.policy = local_ai.load_policy(BASE / "config" / "policy.json")
        self.config = local_ai.load_config(BASE / "config" / "models.json")

    def test_config_has_expected_roles(self):
        self.assertEqual(set(self.config.models), {"coder", "reviewer", "challenger", "triage"})

    def test_loopback_allowed(self):
        for endpoint in ("http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"):
            local_ai.ensure_loopback_endpoint(endpoint)

    def test_non_loopback_rejected(self):
        with self.assertRaises(local_ai.PolicyError):
            local_ai.ensure_loopback_endpoint("http://192.168.4.27:11434")
        with self.assertRaises(local_ai.PolicyError):
            local_ai.ensure_loopback_endpoint("https://127.0.0.1:11434")

    def test_custom_loopback_hostname_is_rejected(self):
        with self.assertRaises(local_ai.PolicyError):
            local_ai.ensure_loopback_endpoint("http://ollama.local:11434")

    def test_endpoint_path_query_and_credentials_are_rejected(self):
        for endpoint in (
            "http://127.0.0.1:11434/api/tags",
            "http://127.0.0.1:11434?target=elsewhere",
            "http://user:pass@127.0.0.1:11434",
        ):
            with self.assertRaises(local_ai.PolicyError):
                local_ai.ensure_loopback_endpoint(endpoint)

    def test_redaction(self):
        text = "Bearer abcdefghijklmnop refresh_token=very-secret-value eric@example.com 336-555-1212 4111 1111 1111 1111 123-45-6789 sk-abcdefghijklmnopqrstuv"
        result = local_ai.redact_text(text)
        self.assertGreaterEqual(result.replacements, 6)
        self.assertNotIn("very-secret-value", result.text)
        self.assertNotIn("eric@example.com", result.text)
        self.assertEqual(len(result.sha256), 64)

    def test_private_key_redacted(self):
        text = "-----BEGIN PRIVATE KEY-----\nSYNTHETIC\n-----END PRIVATE KEY-----"
        result = local_ai.redact_text(text)
        self.assertNotIn("SYNTHETIC", result.text)

    def test_truncate_preserves_ends(self):
        value = "A" * 100 + "B" * 100
        result = local_ai.truncate_middle(value, 80)
        self.assertLessEqual(len(result), 80)
        self.assertTrue(result.startswith("A"))
        self.assertTrue(result.endswith("B"))

    def test_tiny_truncation_limit_stays_bounded(self):
        result = local_ai.truncate_middle("A" * 200, 8)
        self.assertEqual(len(result), 8)

    def test_path_restriction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            allowed = root / "source.swift"
            allowed.write_text("ok")
            self.assertEqual(local_ai.validate_path(allowed, root, self.policy), allowed.resolve())
            denied = root / "identity.p12"
            denied.write_text("synthetic")
            with self.assertRaises(local_ai.PolicyError):
                local_ai.validate_path(denied, root, self.policy)

    def test_denied_path_name_is_case_insensitive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            secrets = root / "secrets"
            secrets.mkdir()
            source = secrets / "notes.txt"
            source.write_text("synthetic")
            with self.assertRaises(local_ai.PolicyError):
                local_ai.validate_path(source, root, self.policy)

    def test_outside_path_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root.parent / "outside-local-ai-test.txt"
            outside.write_text("no")
            try:
                with self.assertRaises(local_ai.PolicyError):
                    local_ai.validate_path(outside, root, self.policy)
            finally:
                outside.unlink(missing_ok=True)

    def test_environment_scrubbing(self):
        clean = local_ai.scrub_environment({"PATH": "/bin", "QUICKBOOKS_CLIENT_SECRET": "x", "NORMAL": "yes"}, self.policy)
        self.assertIn("PATH", clean)
        self.assertIn("NORMAL", clean)
        self.assertNotIn("QUICKBOOKS_CLIENT_SECRET", clean)
        self.assertEqual(clean["GUNNAIRE_PROVIDER_WRITES_DISABLED"], "1")

    def test_fenced_json_parsing(self):
        self.assertEqual(local_ai.parse_json_object('```json\n{"risk":"low"}\n```')["risk"], "low")

    def test_plain_text_rejected(self):
        with self.assertRaises(local_ai.OllamaError):
            local_ai.parse_json_object("not json")

    def test_model_matching(self):
        self.assertTrue(local_ai.model_matches("gpt-oss:20b", "gpt-oss:20b"))
        self.assertTrue(local_ai.model_matches("devstral-small-2:latest", "devstral-small-2"))
        self.assertFalse(local_ai.model_matches("gpt-oss:120b", "gpt-oss:20b"))

    def test_version_comparison(self):
        self.assertTrue(local_ai.version_at_least("0.13.3", "0.13.3"))
        self.assertTrue(local_ai.version_at_least("0.14.0", "0.13.3"))
        self.assertFalse(local_ai.version_at_least("0.13.2", "0.13.3"))
        self.assertFalse(local_ai.version_at_least(None, "0.13.3"))

    def test_high_risk_forces_human_approval(self):
        class Fake:
            def chat(self, model, system, user, options):
                return ({"summary": "x", "findings": [], "risk": "high", "needs_human_approval": False}, {"elapsed_seconds": 0.1, "model": model})
        result = local_ai.advisory_request("reviewer", "review firewall", "firewall", self.config, self.policy, Fake())
        self.assertTrue(result["needs_human_approval"])
        self.assertTrue(result["_local_ai_metadata"]["advisory_only"])

    def test_client_parses_response(self):
        payload = {"model": "devstral-small-2:24b", "message": {"content": '{"summary":"ok","risk":"low"}'}, "eval_count": 3}
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def read(self): return json.dumps(payload).encode()
        with mock.patch("urllib.request.urlopen", return_value=Response()):
            result, metrics = local_ai.OllamaClient("http://127.0.0.1:11434").chat("devstral-small-2:24b", "s", "u", {})
        self.assertEqual(result["summary"], "ok")
        self.assertEqual(metrics["eval_count"], 3)


if __name__ == "__main__":
    unittest.main()
