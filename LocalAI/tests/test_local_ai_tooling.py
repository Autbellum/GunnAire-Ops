from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

LOCAL_AI_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOCAL_AI_DIR))

import benchmark
import local_ai
import qa_runner


class LocalAIToolingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = local_ai.load_policy(LOCAL_AI_DIR / "config" / "policy.json")
        self.config = local_ai.load_config(LOCAL_AI_DIR / "config" / "models.json")

    def test_loopback_endpoints_are_accepted(self) -> None:
        local_ai.ensure_loopback_endpoint("http://127.0.0.1:11434")
        local_ai.ensure_loopback_endpoint("http://localhost:11434")
        local_ai.ensure_loopback_endpoint("http://[::1]:11434")

    def test_non_loopback_and_https_endpoints_are_rejected(self) -> None:
        with self.assertRaises(local_ai.PolicyError):
            local_ai.ensure_loopback_endpoint("http://192.168.4.27:11434")
        with self.assertRaises(local_ai.PolicyError):
            local_ai.ensure_loopback_endpoint("https://127.0.0.1:11434")

    def test_redaction_removes_secrets_and_personal_information(self) -> None:
        source = """
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz
        refresh_token=synthetic-refresh-secret
        eric@example.com 336-555-1212 123-45-6789
        4111 1111 1111 1111
        """
        result = local_ai.redact_text(source)
        self.assertGreaterEqual(result.replacements, 6)
        self.assertNotIn("synthetic-refresh-secret", result.text)
        self.assertNotIn("eric@example.com", result.text)
        self.assertNotIn("4111 1111 1111 1111", result.text)
        self.assertEqual(len(result.digest), 64)

    def test_private_key_block_is_redacted(self) -> None:
        result = local_ai.redact_text("-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----")
        self.assertNotIn("synthetic", result.text)
        self.assertIn("REDACTED:private-key", result.text)

    def test_path_access_stays_inside_repo_and_blocks_key_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            allowed = root / "notes.txt"
            allowed.write_text("ok", encoding="utf-8")
            self.assertEqual(local_ai.validate_readable_path(allowed, root, self.policy), allowed.resolve())
            key = root / "signing.p12"
            key.write_text("synthetic", encoding="utf-8")
            with self.assertRaises(local_ai.PolicyError):
                local_ai.validate_readable_path(key, root, self.policy)
            outside = root.parent / "outside-local-ai-test.txt"
            outside.write_text("no", encoding="utf-8")
            try:
                with self.assertRaises(local_ai.PolicyError):
                    local_ai.validate_readable_path(outside, root, self.policy)
            finally:
                outside.unlink(missing_ok=True)

    def test_sensitive_environment_values_are_removed(self) -> None:
        scrubbed = local_ai.scrub_environment(
            {
                "PATH": "/usr/bin",
                "QUICKBOOKS_CLIENT_SECRET": "synthetic",
                "STRIPE_API_KEY": "synthetic",
                "NORMAL_SETTING": "yes",
            },
            self.policy,
        )
        self.assertIn("PATH", scrubbed)
        self.assertIn("NORMAL_SETTING", scrubbed)
        self.assertNotIn("QUICKBOOKS_CLIENT_SECRET", scrubbed)
        self.assertNotIn("STRIPE_API_KEY", scrubbed)
        self.assertEqual(scrubbed["GUNNAIRE_PROVIDER_WRITES_DISABLED"], "1")

    def test_structured_json_parser_accepts_fences_and_rejects_plain_text(self) -> None:
        self.assertEqual(local_ai.parse_json_object('```json\n{"risk":"low"}\n```')["risk"], "low")
        with self.assertRaises(local_ai.OllamaError):
            local_ai.parse_json_object("not json")

    def test_model_name_matching(self) -> None:
        self.assertTrue(local_ai.model_name_matches("gpt-oss:20b", "gpt-oss:20b"))
        self.assertTrue(local_ai.model_name_matches("devstral-small-2:latest", "devstral-small-2"))
        self.assertFalse(local_ai.model_name_matches("gpt-oss:120b", "gpt-oss:20b"))

    def test_high_risk_request_forces_human_approval(self) -> None:
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

    def test_ollama_client_parses_structured_chat_response(self) -> None:
        payload = {"model": "devstral-small-2:24b", "message": {"content": '{"summary":"ok","risk":"low"}'}, "eval_count": 12}

        class FakeResponse:
            def __enter__(self):
                return self
            def __exit__(self, exc_type, exc, tb):
                return False
            def read(self):
                return json.dumps(payload).encode("utf-8")

        with mock.patch("urllib.request.urlopen", return_value=FakeResponse()):
            client = local_ai.OllamaClient("http://127.0.0.1:11434")
            result, metrics = client.chat(model="devstral-small-2:24b", system_prompt="system", user_prompt="user")
        self.assertEqual(result["summary"], "ok")
        self.assertEqual(metrics["eval_count"], 12)

    def test_configured_suites_and_benchmark_cases_load(self) -> None:
        suites = qa_runner.load_suites(LOCAL_AI_DIR / "config" / "suites.json")
        cases = benchmark.load_cases(LOCAL_AI_DIR / "config" / "benchmark_cases.json")
        self.assertIn("local-tooling", suites)
        self.assertEqual(len(cases), 6)

    def test_command_exit_code_remains_authoritative(self) -> None:
        passed = qa_runner.run_command([sys.executable, "-c", "print('pass')"], cwd=Path.cwd(), timeout_seconds=10, environment=os.environ)
        failed = qa_runner.run_command([sys.executable, "-c", "raise SystemExit(7)"], cwd=Path.cwd(), timeout_seconds=10, environment=os.environ)
        self.assertTrue(passed["passed"])
        self.assertFalse(failed["passed"])
        self.assertEqual(failed["exit_code"], 7)

    def test_failed_suite_can_run_without_calling_ai(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "README.md").write_text("test", encoding="utf-8")
            suite = qa_runner.Suite(
                name="synthetic-failure",
                description="failure",
                commands=((sys.executable, "-c", "raise SystemExit(3)"),),
                timeout_seconds=10,
                ai_on_failure=True,
                model_role="coder",
            )
            code, report_path, report = qa_runner.run_suite(
                suite,
                repo=root,
                report_root=root / "reports",
                use_ai=False,
                models_path=LOCAL_AI_DIR / "config" / "models.json",
                policy_path=LOCAL_AI_DIR / "config" / "policy.json",
                endpoint=None,
            )
            self.assertEqual(code, 1)
            self.assertFalse(report["passed"])
            self.assertFalse(report["ai_called"])
            self.assertTrue(report_path.exists())

    def test_benchmark_scoring_rewards_required_safety_controls(self) -> None:
        score = benchmark.score_response(
            {"required_concepts": ["deny", "least privilege"], "forbidden_concepts": ["approve the rule"], "human_approval_required": True},
            {"findings": ["deny by default and apply least privilege"], "risk": "critical", "needs_human_approval": True},
        )
        self.assertEqual(score["percentage"], 100.0)


if __name__ == "__main__":
    unittest.main()
