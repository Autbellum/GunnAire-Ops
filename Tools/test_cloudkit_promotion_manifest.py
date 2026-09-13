import copy
import tempfile
import unittest
from pathlib import Path

try:
    from Tools import cloudkit_promotion_manifest, release_preflight
except ModuleNotFoundError:  # Direct execution from the Tools directory.
    import cloudkit_promotion_manifest
    import release_preflight


class CloudKitPromotionManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.production = {
            record_name: {}
            for record_name in release_preflight.EXPECTED_CLOUDKIT_BASELINE_RECORD_TYPES
        }
        self.development = copy.deepcopy(self.production)
        for record_name, fields in release_preflight.EXPECTED_CLOUDKIT_V27_ADDITIONS.items():
            self.development.setdefault(record_name, {}).update(fields)

        metadata = {
            "system_fields": release_preflight.EXPECTED_CLOUDKIT_SYSTEM_FIELDS,
            "grants": release_preflight.EXPECTED_CLOUDKIT_RECORD_GRANTS,
        }
        self.production_metadata = {
            record_name: copy.deepcopy(metadata) for record_name in self.production
        }
        self.development_metadata = {
            record_name: copy.deepcopy(metadata) for record_name in self.development
        }

    def manifest(self, **overrides):
        return cloudkit_promotion_manifest.build_manifest(
            overrides.get("development", self.development),
            overrides.get("production", self.production),
            overrides.get("development_metadata", self.development_metadata),
            overrides.get("production_metadata", self.production_metadata),
            development_sha256="development-hash",
            production_sha256="production-hash",
        )

    def test_exact_v27_delta_is_additive_and_safe_to_promote(self) -> None:
        manifest = self.manifest()

        self.assertTrue(manifest["summary"]["safeToPromote"])
        self.assertEqual(manifest["summary"]["riskClassification"], "additive-only")
        self.assertEqual(manifest["summary"]["addedRecordTypeCount"], 9)
        self.assertEqual(
            manifest["summary"]["addedFieldCount"],
            sum(
                len(fields)
                for fields in release_preflight.EXPECTED_CLOUDKIT_V27_ADDITIONS.values()
            ),
        )
        self.assertEqual(manifest["changes"]["changedOrRemovedFields"], [])
        self.assertTrue(all(manifest["checks"].values()))

    def test_changed_existing_field_blocks_promotion(self) -> None:
        production = copy.deepcopy(self.production)
        production["CD_Invoice"]["CD_amount"] = ("DOUBLE", "QUERYABLE")
        development = copy.deepcopy(self.development)
        development["CD_Invoice"]["CD_amount"] = ("STRING", "QUERYABLE")

        manifest = self.manifest(development=development, production=production)

        self.assertFalse(manifest["summary"]["safeToPromote"])
        self.assertEqual(manifest["summary"]["riskClassification"], "blocked")
        self.assertEqual(
            manifest["changes"]["changedOrRemovedFields"][0]["path"],
            "CD_Invoice.CD_amount",
        )

    def test_changed_existing_security_grant_blocks_promotion(self) -> None:
        development_metadata = copy.deepcopy(self.development_metadata)
        development_metadata["CD_AppUser"]["grants"] = ('GRANT READ TO "_world"',)

        manifest = self.manifest(development_metadata=development_metadata)

        self.assertFalse(manifest["summary"]["safeToPromote"])
        self.assertEqual(
            manifest["changes"]["changedExistingMetadata"], ["CD_AppUser"]
        )

    def test_unapproved_added_record_grant_blocks_promotion(self) -> None:
        development_metadata = copy.deepcopy(self.development_metadata)
        development_metadata["CD_BusinessTask"]["grants"] = (
            'GRANT READ TO "_world"',
        )

        manifest = self.manifest(development_metadata=development_metadata)

        self.assertFalse(manifest["summary"]["safeToPromote"])
        self.assertEqual(
            manifest["changes"]["invalidAddedRecordMetadata"],
            ["CD_BusinessTask"],
        )

    def test_partial_v23_delta_blocks_promotion(self) -> None:
        development = copy.deepcopy(self.development)
        development["CD_ServiceCall"].pop("CD_visitDispositionNotes")

        manifest = self.manifest(development=development)

        self.assertFalse(manifest["summary"]["safeToPromote"])
        self.assertIn(
            "CD_ServiceCall.CD_visitDispositionNotes",
            manifest["changes"]["missingOrChangedDevelopmentV23Fields"],
        )

    def test_manifest_write_is_atomic_and_round_trips(self) -> None:
        manifest = self.manifest()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "promotion.json"
            cloudkit_promotion_manifest.write_manifest(path, manifest)

            restored = __import__("json").loads(path.read_text(encoding="utf-8"))

        self.assertEqual(restored, manifest)

    def test_v25_still_requires_the_original_receipt_field(self) -> None:
        production = copy.deepcopy(self.development)
        production["CD_Item"].pop("CD_quickBooksCatalogReceiptJSON")
        manifest = self.manifest(production=production, production_metadata=self.development_metadata)
        self.assertTrue(manifest["summary"]["safeToPromote"])
        self.assertEqual(manifest["summary"]["addedFieldCount"], 1)
        self.assertEqual(manifest["summary"]["addedRecordTypeCount"], 0)
        self.assertEqual(manifest["targetBootstrapVersion"], 27)

    def test_v27_adds_only_optional_invoice_review_to_complete_v26(self) -> None:
        production = copy.deepcopy(self.development)
        production["CD_Invoice"].pop("CD_quickBooksPaymentReviewJSON")
        manifest = self.manifest(production=production, production_metadata=self.development_metadata)
        self.assertTrue(manifest["summary"]["safeToPromote"])
        self.assertEqual(manifest["summary"]["addedFieldCount"], 1)
        self.assertEqual(manifest["summary"]["addedRecordTypeCount"], 0)
        for definition in [None, ("DOUBLE", "QUERYABLE")]:
            development = copy.deepcopy(self.development)
            development["CD_Invoice"].pop("CD_quickBooksPaymentReviewJSON")
            if definition is not None:
                development["CD_Invoice"]["CD_quickBooksPaymentReviewJSON"] = definition
            candidate = self.manifest(development=development, production=production,
                                      production_metadata=self.development_metadata)
            self.assertFalse(candidate["summary"]["safeToPromote"])
            self.assertIn("CD_Invoice.CD_quickBooksPaymentReviewJSON",
                          candidate["changes"]["missingOrChangedDevelopmentV27Fields"])

    def test_v25_adds_only_two_optional_item_fields_to_complete_v24(self) -> None:
        production = copy.deepcopy(self.development)
        production["CD_Item"].pop("CD_quickBooksInventorySetupJSON")
        production["CD_Item"].pop("CD_quickBooksCatalogDetailsJSON")
        manifest = self.manifest(production=production, production_metadata=self.development_metadata)
        self.assertTrue(manifest["summary"]["safeToPromote"])
        self.assertEqual(manifest["summary"]["addedFieldCount"], 2)
        self.assertEqual(manifest["summary"]["addedRecordTypeCount"], 0)
        for field in ["CD_quickBooksInventorySetupJSON", "CD_quickBooksCatalogDetailsJSON"]:
            for definition in [None, ("DOUBLE", "QUERYABLE")]:
                development = copy.deepcopy(self.development)
                development["CD_Item"].pop(field)
                if definition is not None:
                    development["CD_Item"][field] = definition
                candidate = self.manifest(development=development, production=production,
                                          production_metadata=self.development_metadata)
                self.assertFalse(candidate["summary"]["safeToPromote"])
                self.assertIn("CD_Item." + field, candidate["changes"]["missingOrChangedDevelopmentV25Fields"])

    def test_missing_or_malformed_receipt_field_blocks_promotion(self) -> None:
        for definition in [None, ("DOUBLE", "QUERYABLE")]:
            development = copy.deepcopy(self.development)
            development["CD_Item"].pop("CD_quickBooksCatalogReceiptJSON")
            if definition is not None:
                development["CD_Item"]["CD_quickBooksCatalogReceiptJSON"] = definition
            manifest = self.manifest(development=development)
            self.assertFalse(manifest["summary"]["safeToPromote"])
            self.assertIn("CD_Item.CD_quickBooksCatalogReceiptJSON",
                          manifest["changes"]["missingOrChangedDevelopmentV24Fields"])

    def test_v26_adds_only_optional_milestone_receipt_to_complete_v25(self) -> None:
        production = copy.deepcopy(self.development)
        production["CD_Invoice"].pop("CD_milestoneDraftReceiptJSON")
        manifest = self.manifest(production=production, production_metadata=self.development_metadata)
        self.assertTrue(manifest["summary"]["safeToPromote"])
        self.assertEqual(manifest["summary"]["addedFieldCount"], 1)
        self.assertEqual(manifest["summary"]["addedRecordTypeCount"], 0)
        for definition in [None, ("DOUBLE", "QUERYABLE")]:
            development = copy.deepcopy(self.development)
            development["CD_Invoice"].pop("CD_milestoneDraftReceiptJSON")
            if definition is not None:
                development["CD_Invoice"]["CD_milestoneDraftReceiptJSON"] = definition
            candidate = self.manifest(development=development, production=production,
                                      production_metadata=self.development_metadata)
            self.assertFalse(candidate["summary"]["safeToPromote"])
            self.assertIn("CD_Invoice.CD_milestoneDraftReceiptJSON",
                          candidate["changes"]["missingOrChangedDevelopmentV26Fields"])


if __name__ == "__main__":
    unittest.main()
