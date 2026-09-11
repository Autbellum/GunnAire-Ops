from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE))
import qa_runner


class QATests(unittest.TestCase):
    def test_load_suites(self):
        suites = qa_runner.load_suites(BASE / "config" / "suites.json")
        self.assertIn("local-tooling", suites)

    def test_success_and_failure_are_authoritative(self):
        success = qa_runner.run_command([sys.executable, "-c", "print('ok')"], Path.cwd(), 5, os.environ)
        failure = qa_runner.run_command([sys.executable, "-c", "raise SystemExit(7)"], Path.cwd(), 5, os.environ)
        self.assertTrue(success["passed"])
        self.assertFalse(failure["passed"])
        self.assertEqual(failure["exit_code"], 7)

    def test_timeout_is_failure(self):
        result = qa_runner.run_command(
            [sys.executable, "-c", "import time; print('before'); time.sleep(2)"],
            Path.cwd(), 1, os.environ,
        )
        self.assertFalse(result["passed"])
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["exit_code"], 124)

    def test_no_ai_stops_after_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("test")
            marker = root / "bad"
            suite = qa_runner.Suite(
                "synthetic", "test",
                ((sys.executable, "-c", "raise SystemExit(3)"), (sys.executable, "-c", f"open({str(marker)!r}, 'w').write('x')")),
                5, True, "coder",
            )
            code, path, report = qa_runner.run_suite(
                suite, root, root / "reports", False,
                BASE / "config" / "models.json", BASE / "config" / "policy.json", None,
            )
            self.assertEqual(code, 1)
            self.assertFalse(report["passed"])
            self.assertFalse(report["ai_called"])
            self.assertEqual(report["commands_executed"], 1)
            self.assertTrue(path.exists())
            self.assertFalse(marker.exists())

    def test_run_ids_do_not_collide_within_one_second(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("test")
            suite = qa_runner.Suite("quick", "test", ((sys.executable, "-c", "print('ok')"),), 5, False, "triage")
            _, first, _ = qa_runner.run_suite(suite, root, root / "reports", False, BASE / "config" / "models.json", BASE / "config" / "policy.json", None)
            _, second, _ = qa_runner.run_suite(suite, root, root / "reports", False, BASE / "config" / "models.json", BASE / "config" / "policy.json", None)
            self.assertNotEqual(first.parent.name, second.parent.name)


if __name__ == "__main__":
    unittest.main()
