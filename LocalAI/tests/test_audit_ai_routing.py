from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "audit_ai_routing.py"
SPEC = importlib.util.spec_from_file_location("audit_ai_routing", MODULE_PATH)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


def policy() -> dict:
    return {
        "policy_name": "test local-first policy",
        "enforcement": {
            "runtime_source_extensions": [".swift", ".py", ".sh"],
            "scan_extensions": [".swift", ".py", ".sh", ".md", ".json"],
            "skip_directories": [".git"],
            "scanner_exempt_paths": ["LocalAI/audit_ai_routing.py"],
            "test_path_fragments": ["/tests/", "/test_", "Tests/", "UITests/"],
            "stable_diffusion_allowed_path_prefixes": ["ImageAI/", "VisualAI/", "AppStoreAssets/"],
            "stable_diffusion_allow_marker": "AI_ROUTING_ALLOW_IMAGE_PROVIDER",
            "hosted_provider_allow_marker": "AI_ROUTING_ALLOW_HOSTED_PROVIDER",
            "direct_mobile_ollama_allow_marker": "AI_ROUTING_ALLOW_DIRECT_MOBILE_OLLAMA",
        },
    }


class AIRoutingAuditTests(unittest.TestCase):
    def run_audit(self, files: dict[str, str]) -> dict:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative, content in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            return AUDIT.audit_repository(root, policy())

    def test_rejects_stable_diffusion_for_business_text(self) -> None:
        report = self.run_audit({
            "GunnAire Ops/BusinessSummary.swift": 'let engine = "Stable Diffusion"\n'
        })
        self.assertEqual(report["status"], "violations_found")
        self.assertIn("AI-SD-NONIMAGE", {item["code"] for item in report["violations"]})

    def test_rejects_camel_case_stable_diffusion_client(self) -> None:
        report = self.run_audit({
            "Backend/business_text.py": "client = StableDiffusionClient()\n"
        })
        self.assertEqual(report["status"], "violations_found")
        self.assertIn("AI-SD-NONIMAGE", {item["code"] for item in report["violations"]})

    def test_allows_stable_diffusion_in_image_provider_path(self) -> None:
        report = self.run_audit({
            "ImageAI/StableDiffusionGenerator.swift": 'let route = "/sdapi/v1/txt2img"\n'
        })
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["counts"]["stable_diffusion_matches"], 1)

    def test_allows_negative_provider_metadata_without_treating_it_as_use(self) -> None:
        report = self.run_audit({
            "GunnAire Ops/LocalAIResponse.swift": "let stableDiffusionUsed = false\n"
        })
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["counts"]["violations"], 0)

    def test_allows_explicit_image_only_policy_statement(self) -> None:
        report = self.run_audit({
            "Backend/local_gateway.py": 'print("Stable Diffusion is image-only and excluded from business text")\n'
        })
        self.assertEqual(report["status"], "pass")

    def test_allows_image_provider_policy_validation(self) -> None:
        report = self.run_audit({
            "Backend/local_gateway.py": 'if value.get("image_generation", {}).get("provider") != "stable-diffusion":\n    raise RuntimeError("Stable Diffusion must remain isolated as the image provider")\n'
        })
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["counts"]["violations"], 0)

    def test_rejects_direct_hosted_llm_endpoint(self) -> None:
        report = self.run_audit({
            "Backend/business_ai.py": 'endpoint = "https://api.openai.com/v1/responses"\n'
        })
        self.assertEqual(report["status"], "violations_found")
        self.assertIn("AI-HOSTED-DIRECT", {item["code"] for item in report["violations"]})

    def test_rejects_direct_mobile_ollama_access(self) -> None:
        report = self.run_audit({
            "GunnAire Ops/LocalAIClient.swift": 'let endpoint = "http://127.0.0.1:11434/api/chat"\n'
        })
        self.assertEqual(report["status"], "violations_found")
        self.assertIn("AI-MOBILE-DIRECT-OLLAMA", {item["code"] for item in report["violations"]})

    def test_allows_mobile_to_validate_backend_provider_metadata(self) -> None:
        report = self.run_audit({
            "GunnAire Ops/LocalAIResponse.swift": 'guard provider == "ollama" else { return }\n'
        })
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["counts"]["local_llm_matches"], 1)

    def test_allows_backend_to_use_loopback_ollama(self) -> None:
        report = self.run_audit({
            "Backend/local_ai_gateway.py": 'OLLAMA = "http://127.0.0.1:11434/api/chat"\n'
        })
        self.assertEqual(report["status"], "pass")
        self.assertGreaterEqual(report["counts"]["local_llm_matches"], 1)

    def test_test_fixtures_do_not_trigger_runtime_violation(self) -> None:
        report = self.run_audit({
            "Backend/tests/test_provider.py": 'endpoint = "https://api.openai.com/v1/responses"\n'
        })
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["counts"]["hosted_llm_matches"], 1)

    def test_candidate_files_are_ranked_without_replacing_logic(self) -> None:
        report = self.run_audit({
            "GunnAire Ops/CustomerIntelligence.swift": "func summarizeAndRecommend() { /* draft insight */ }\n",
            "GunnAire Ops/PlainModel.swift": "struct PlainModel {}\n",
        })
        candidates = report["candidate_business_ai_files"]
        self.assertEqual(candidates[0]["path"], "GunnAire Ops/CustomerIntelligence.swift")
        self.assertGreater(candidates[0]["score"], 0)

    def test_json_policy_is_serializable(self) -> None:
        json.dumps(policy())


if __name__ == "__main__":
    unittest.main()
