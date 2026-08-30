import contextlib
import copy
import io
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    from Tools import release_preflight
except ModuleNotFoundError:  # Direct execution from the Tools directory.
    import release_preflight


class CloudKitV20PreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.production = {
            record_name: {}
            for record_name in release_preflight.EXPECTED_CLOUDKIT_BASELINE_RECORD_TYPES
        }
        self.development = copy.deepcopy(self.production)
        for record_name, fields in release_preflight.EXPECTED_CLOUDKIT_V20_ADDITIONS.items():
            self.development.setdefault(record_name, {}).update(fields)

    def check(self, development: dict, production: dict) -> release_preflight.Results:
        def schema(path: Path) -> dict:
            return development if path.name == "development.ckdb" else production

        results = release_preflight.Results()
        with patch.object(release_preflight, "parse_cloudkit_schema", side_effect=schema), \
             patch.object(release_preflight, "sha256", return_value="synthetic"), \
             contextlib.redirect_stdout(io.StringIO()):
            release_preflight.check_cloudkit(
                Path("development.ckdb"),
                Path("production.ckdb"),
                results,
            )
        return results

    def test_exact_cumulative_v20_schema_is_accepted(self) -> None:
        results = self.check(self.development, self.production)

        self.assertEqual(results.failures, [])
        self.assertEqual(results.warnings, 0)

    def test_partial_business_task_pair_is_rejected(self) -> None:
        partial_development = copy.deepcopy(self.development)
        partial_development.pop("CD_BusinessTaskEvent")

        results = self.check(partial_development, self.production)

        self.assertTrue(results.failures)
        self.assertTrue(any("record types" in failure.lower() for failure in results.failures))


if __name__ == "__main__":
    unittest.main()
