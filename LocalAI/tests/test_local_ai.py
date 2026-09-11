from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

LOCAL_AI_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOCAL_AI_DIR))

import local_ai


class LocalAITests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = local_ai.load_config(LOCAL_AI_DIR / "config" / "models.json")
        self.policy = local_ai.load_policy(LOCAL_AI_DIR / "config" / "policy.json")

    def test_config_has_required_roles(self) -> None:
        self.assertTrue(self.config.roles["coder"].required)
        self.assertTrue(self.config.roles["reviewer"].required)
        self.assertFalse(self.config.roles["challenger"].required)

    def test_loopback_endpoints_allowed(self) -> None:
        local_ai.ensure_loopback_endpoint("http://127.0.0.1:11434")
        local_ai.ensure_loopback_endpoint("http://localhost:11434")
        local_ai.ensure_loopback_endpoint("http://[::1]:11434")

    def test_non_loopback_and_https_rejected(self) -> None:
        with self.assertRaises(local_ai.PolicyError):
            local_ai.ensure_loopback_endpoint("http://192.168.4.27:11434")
        with self.assertRaises(local_ai.PolicyError):
            local_ai.ensure_loopback_endpoint("https://127.0.0.1:11434")

    def test_credentials_in_endpoint_rejected(self) -> None:
        with self.assertRaises(local_ai.PolicyError):
            local_ai.ensure_loopback_endpoint("http://user:pass@127.0.0.1:11434")

    def test_redaction_removes_secrets_and_pii(self) -> None:
        source = """
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz
        refresh_token=super-secret-refresh-token
        eric@example.com 336-555-1212
        4111 1111 1111 1111 123-45-6789
        sk-abcdefghijklmnopqrstuvwxyz123456
        """
        result = local_ai.redact_text(source)
        self.assertGreaterEqual(result.replacements, 7)
        for raw in ("super-secret-refresh-token", "eric@example.com", "4111 1111 1111 1111", "123-45-6789"):
            self.assertNotIn(raw, result.text)
        self.assertEqual(len(result.digest), 64)

    def test_private_key_redacted(self) -> None:
        source = "-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----"
        result = local_ai.redact_text(source)
        self.assertNotIn("synthetic", result.text)
        self.assertIn("REDACTED:private-key", result.text)

    def test_truncate_middle_keeps_both_ends(self) -> None:
        bounded = local_ai.truncate_middle("A" * 100 + "B" * 100, 80)
        self.assertLessEqual(len(bounded), 80)
        self.assertTrue(bounded.startswith("A"))
        self.assertTrue(bounded.endswith("B"))
        self.assertIn("TRUNCATED", bounded)

    def test_path_must_be_inside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            allowed = root / "notes.txt"
            allowed.write_text("ok", encoding="utf-8")
            self.assertEqual(local_ai.validate_readable_path(allowed, root, self.policy), allowed.resolve())
            outside = root.parent / "outside-local-ai-test.txt"
            outside.write_text("no", encoding="utf-8")
            try:
                with self.assertRaises(local_ai.PolicyError):
                    local_ai.validate_readable_path(outside, root, self.policy)
            finally:
                outside.unlink(missing_ok=True)

    def test_signing_file_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            secret = root / "signing.p12"
            secret.write_text("synthetic", encoding="utf-8")
            with self.assertRaises(local_ai.PolicyError):
                local_ai.validate_readable_path(secret, root, self.policy)

    def test_denied_directory_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            denied = root / "Secrets"
            denied.mkdir()
            file = denied / "notes.txt"
            file.write_text("synthetic", encoding="utf-8")
            with self.assertRaises(local_ai.PolicyError):
                local_ai.validate_readable_path(file, root, self.policy)

    def test_environment_scrubbing(self) -> None:
        clean = local_ai.scrub_environment(
            {
                "PATH": "/usr/bin",
                "QUICKBOOKS_CLIENT_SECRET": "secret",
                "STRIPE_API_KEY": "secret",
                "NORMAL_SETTING": "yes",
            },
            self.policy,
        )
        self.assertIn("PATH", clean)
        self.assertIn("NORMAL_SETTING", clean)
        self.assertNotIn("QUICKBOOKS_CLIENT_SECRET", clean)
        self.assertNotIn("STRIPE_API_KEY", clean)
        self.assertEqual(clean["GUNNAIRE_PROVIDER_WRITES_DISABLED"], "1")

    def test_parse_fenced_json(self) -> None:
        self.assertEqual(local_ai.parse_json_object('```json\n{"risk":"low"}\n```')["risk"], "low")

    def test_parse_embedded_json(self) -> None:
        self.assertEqual(local_ai.parse_json_object('prefix {"summary":"ok"} suffix')["summary"], "ok")

    def test_parse_invalid_response_rejected(self) -> None:
        with self.assertRaises(local_ai.OllamaError):
            local_ai.parse_json_object("not json")

    def test_model_name_match(self) -> None:
        self.assertTrue(local_ai.model_name_matches("gpt-oss:20b", "gpt-oss:20b"))
        self.assertTrue(local_ai.model_name_matches("devstral-small-2:latest", "devstral-small-2"))
        self.assertFalse(local_ai.model_name_matches("gpt-oss:120b", "gpt-oss:20b"))

    def test_high_risk_request_forces_approval(self) -> None:
        class FakeClient:
            def chat(self, **kwargs):
                return ({"summary": "reviewed", "findings": [], "risk": "high", "needs_human_approval": False}, {"elapsed_seconds": 0.1, "model": kwargs["model"]})

        result = local_ai.advisory_request(
            role="reviewer",
            prompt="Review firewall rules",
            domain="firewall",
            config=self.config,
            policy=self.policy,
            client=FakeClient(),
        )
        self.assertTrue(result["needs_human_approval"])
        self.assertTrue(result["_local_ai_metadata"]["advisory_only"])

    def test_unknown_role_rejected(self) -> None:
        class FakeClient:
            pass
        with self.assertRaises(local_ai.PolicyError):
            local_ai.advisory_request(role="owner", prompt="x", domain="coding", config=self.config, policy=self.policy, client=FakeClient())

    def test_ollama_tags_parsed(self) -> None:
        payload = {"models": [{"name": "gpt-oss:20b"}, {"name": "devstral-small-2:24b"}]}

        class FakeResponse:
            def __enter__(self): return self
            def __exit__(self, exc_type, exc, tb): return False
            def read(self): return json.dumps(payload).encode("utf-8")

        with mock.patch("urllib.request.urlopen", return_value=FakeResponse()):
            client = local_ai.OllamaClient("http://127.0.0.1:11434")
            self.assertEqual(client.tags(), ["devstral-small-2:24b", "gpt-oss:20b"])

    def test_ollama_chat_parsed(self) -> None:
        payload = {"model": "gpt-oss:20b", "message": {"content": '{"summary":"ok","risk":"low"}'}, "eval_count": 12}

        class FakeResponse:
            def __enter__(self): return self
            def __exit__(self, exc_type, exc, tb): return False
            def read(self): return json.dumps(payload).encode("utf-8")

        with mock.patch("urllib.request.urlopen", return_value=FakeResponse()):
            result, metrics = local_ai.OllamaClient("http://127.0.0.1:11434").chat(
                model="gpt-oss:20b", system_prompt="system", user_prompt="user", generation={}
            )
        self.assertEqual(result["summary"], "ok")
        self.assertEqual(metrics["eval_count"], 12)

    def test_doctor_reports_missing_required(self) -> None:
        class FakeClient:
            def tags(self): return ["qwen2.5-coder:7b"]
        result = local_ai.doctor(self.config, self.policy, FakeClient())
        self.assertEqual(result["status"], "missing-required-models")


if __name__ == "__main__":
    unittest.main()
