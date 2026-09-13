import json
from pathlib import Path
import re
import unittest

from Backend.generate_document_content_proof_fixture import capture
from Backend import gunnaire_backend as backend
from Backend import test_cloudkit_staff_shares as sharing_tests


class DocumentContentProofFixtureTests(unittest.TestCase):
    def test_actual_http_contract_matches_bundled_native_fixture(self):
        def stable(value):
            if isinstance(value, dict):
                return {key: stable(item) for key, item in value.items()}
            if isinstance(value, str):
                if re.fullmatch(r"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", value):
                    return "<uuid>"
                if re.fullmatch(r"[0-9a-f]{64}", value):
                    return "<digest>"
                if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})", value):
                    return "<instant>"
            return value
        path = Path(__file__).resolve().parents[1] / "GunnAire OpsTests" / "CompanyDocumentContentInterop.json"
        original = (backend.encrypt_catalog_payload, backend.decrypt_catalog_payload)
        self.assertEqual(stable(json.loads(path.read_text())), stable(capture()))
        self.assertEqual((backend.encrypt_catalog_payload, backend.decrypt_catalog_payload), original)

    def test_nested_cloudkit_fixture_restores_crypto_without_runner_cleanup(self):
        original = (backend.encrypt_catalog_payload, backend.decrypt_catalog_payload)
        fixture = sharing_tests.CloudKitStaffSharingTests()
        fixture.setUp()
        try:
            self.assertNotEqual((backend.encrypt_catalog_payload, backend.decrypt_catalog_payload), original)
        finally:
            fixture.tearDown()
        self.assertEqual((backend.encrypt_catalog_payload, backend.decrypt_catalog_payload), original)
