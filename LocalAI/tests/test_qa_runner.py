from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

LOCAL_AI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOCAL_AI))
import qa_runner


class QARunnerTests(unittest.TestCase):
    def test_load_suites(self):
        suites = qa_runner.load_suites(LOCAL_AI / "config" / "suites.json")
        self.assertIn("local-tooling", suites)

    def test_success_and_failure_are_authoritative(self):
        success = qa_runner.run_command([sys.executable, "-c", "print('pass')"], cwd=Path.cwd(), timeout_seconds=10, environment=os.environ)
        failure = qa_runner.run_command([sys.executable, "-c", "raise SystemExit(7)"], cwd=Path.cwd(), timeout_seconds=10, environment=os.environ)
        self.assertTrue(success["passed"])
        self.assertFalse(failure["passed"])
        self.assertEqual(failure["exit_code"], 7)

    def test_no_ai_mode_and_stop_early(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "README.md").write_text("test")
            marker = root / "should-not-exist"
            suite = qa_runner.Suite(
                "synthetic", "test", ((sys.executable, "-c", "raise SystemExit(3)"), (sys.executable, "-c", f"open({str(marker)!r}, 'w').write('bad')")),
                10, True, "coder",
            )
            code, path, report = qa_runner.run_suite(
                suite, repo=root, report_root=root / "reports", use_ai=False,
                models=LOCAL_AI / "config" / "models.json", policy_path=LOCAL_AI / "config" / "policy.json", endpoint=None,
            )
            self.assertEqual(code, 1)
            self.assertFalse(report["passed"])
            self.assertFalse(report["ai_called"])
            self.assertEqual(report["commands_executed"], 1)
            self.assertTrue(path.exists())
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
