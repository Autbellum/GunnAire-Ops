from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "GunnAire Ops"


class LocalAIAppIntegrationContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.service = (APP / "GunnAireLocalAIService.swift").read_text(encoding="utf-8")
        cls.workspace = (APP / "GunnAireLocalAIWorkspace.swift").read_text(encoding="utf-8")
        cls.dashboard = (APP / "OperationsDashboardView.swift").read_text(encoding="utf-8")
        cls.settings = (APP / "SettingsView.swift").read_text(encoding="utf-8")
        cls.gateway = (ROOT / "Backend/local_ai_gateway.py").read_text(encoding="utf-8")
        cls.routes = (ROOT / "Backend/gunnaire_local_ai_backend.py").read_text(encoding="utf-8")
        cls.launcher = (ROOT / "gunnaire_backend.py").read_text(encoding="utf-8")

    def test_swift_client_uses_authenticated_backend_not_direct_ollama(self) -> None:
        self.assertIn('path: "/api/local-ai/status"', self.service)
        self.assertIn('path: "/api/local-ai/assist"', self.service)
        self.assertIn("Config.Backend.normalizedBaseURL", self.service)
        self.assertIn("AppleAuthManager.shared.sessionToken", self.service)
        self.assertIn("GoogleAuthManager.shared.applicationSessionToken", self.service)
        self.assertNotIn(":11434", self.service)
        self.assertNotIn("/api/chat", self.service)
        self.assertNotIn("/api/generate", self.service)

    def test_swift_client_rejects_hosted_or_image_provider_responses(self) -> None:
        self.assertIn("!response.hostedFallbackUsed", self.service)
        self.assertIn("response.hostedCreditsUsed == 0", self.service)
        self.assertIn("!response.stableDiffusionUsed", self.service)
        lowered = (self.service + self.workspace).lower()
        for forbidden in (
            "api.openai.com",
            "api.anthropic.com",
            "generativelanguage.googleapis.com",
            "openrouter.ai",
            "/sdapi/",
            "automatic1111",
            "comfyui",
        ):
            self.assertNotIn(forbidden, lowered)

    def test_workspace_exposes_all_bounded_business_tasks(self) -> None:
        for task in (
            "operations_narrative",
            "customer_email_draft",
            "customer_text_draft",
            "service_note_summary",
            "document_classification",
            "estimate_scope_draft",
            "failure_triage",
            "security_review",
        ):
            self.assertIn(task, self.workspace)
            self.assertIn(f'"{task}"', self.gateway)
        self.assertIn("Every result is advisory and requires staff review", self.workspace)

    def test_operations_context_is_role_filtered_and_deterministic(self) -> None:
        self.assertIn("snapshot.localAIContext(includeFinancials: canViewFinancials)", self.workspace)
        self.assertIn("$0.id != .revenue && $0.id != .accounts", self.workspace)
        self.assertIn("The app's calculations remain authoritative", self.workspace)
        self.assertIn("BusinessSuiteSnapshot", self.workspace)

    def test_command_center_and_settings_expose_local_ai(self) -> None:
        self.assertIn("CommandCenterLocalAIButton", self.dashboard)
        self.assertIn("GunnAireLocalAIWorkspace(", self.dashboard)
        self.assertIn("GunnAireLocalAIReadinessSection()", self.settings)

    def test_backend_routes_require_inherited_authentication(self) -> None:
        self.assertIn('STATUS_PATH = "/api/local-ai/status"', self.routes)
        self.assertIn('ASSIST_PATH = "/api/local-ai/assist"', self.routes)
        self.assertIn("principal = self.principal()", self.routes)
        self.assertIn("actor_role=role", self.routes)
        self.assertIn("hostedCreditsUsed", self.routes)
        self.assertIn("from Backend.gunnaire_local_ai_backend import main", self.launcher)

    def test_gateway_is_local_first_and_has_no_hosted_fallback(self) -> None:
        self.assertIn('endpoint: str = "http://127.0.0.1:11434"', self.gateway)
        self.assertIn('"hostedFallbackEnabled": False', self.gateway)
        self.assertIn('"hostedCreditsUsed": 0', self.gateway)
        self.assertNotIn("api.openai.com", self.gateway.lower())
        self.assertNotIn("api.anthropic.com", self.gateway.lower())
        self.assertNotIn("generativelanguage.googleapis.com", self.gateway.lower())


if __name__ == "__main__":
    unittest.main()
