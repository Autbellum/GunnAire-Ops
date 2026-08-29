from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
BACKEND_ROOT = REPOSITORY_ROOT / "Backend"
sys.path.insert(0, str(REPOSITORY_ROOT))

from Backend import gunnaire_backend as canonical_backend


class DeploymentEntrypointTests(unittest.TestCase):
    def test_render_launcher_uses_the_canonical_backend_main(self) -> None:
        launcher_path = REPOSITORY_ROOT / "gunnaire_backend.py"
        spec = importlib.util.spec_from_file_location("gunnaire_render_launcher", launcher_path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        launcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(launcher)

        self.assertIs(launcher.main, canonical_backend.main)
        self.assertFalse(hasattr(launcher, "qbo_request"))

    def test_render_requirements_delegate_to_the_canonical_dependency_set(self) -> None:
        root_requirements = (REPOSITORY_ROOT / "requirements.txt").read_text(encoding="utf-8").splitlines()
        canonical_requirements = (BACKEND_ROOT / "requirements.txt").read_text(encoding="utf-8")

        self.assertEqual(root_requirements, ["-r Backend/requirements.txt"])
        self.assertIn("cryptography", canonical_requirements)
        self.assertIn("httpx[http2]", canonical_requirements)

    def test_deployed_qbo_client_contract_never_returns_a_refresh_token(self) -> None:
        payload = {
            "access_token": "short-lived-access",
            "refresh_token": "server-only-refresh",
            "expires_in": 3600,
        }

        response = canonical_backend.qbo_client_token_response(payload)

        self.assertEqual(response, {"accessToken": "short-lived-access", "expiresIn": 3600})
        self.assertNotIn("refreshToken", response or {})

    def test_canonical_backend_exposes_a_deployment_version(self) -> None:
        self.assertRegex(canonical_backend.SERVICE_VERSION, r"^\d{4}\.\d{2}\.\d{2}\.\d+$")
        self.assertIn(canonical_backend.SERVICE_VERSION, canonical_backend.GunnAireBackendHandler.server_version)


if __name__ == "__main__":
    unittest.main()
