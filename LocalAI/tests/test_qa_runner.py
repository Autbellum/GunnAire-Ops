from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

LOCAL_AI_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOCAL_AI_DIR))

import qa_runner


class QARunnerTests(unittest.TestCase):
    def test_load_suites(self) -> None:
        suites = qa_runner.load_suites(LOCAL_AI_DIR / "config" / "suites.json")
        self.assertIn("local-tooling", suites)
        self.assertGreaterEqual(len(suites["local-tooling"].commands), 3)

    def test_success_exit_is_authoritative(self) -> None:
        result = qa_runner.run_command(
            [sys.executable, "-c", "print('pass')"], cwd=Path.cwd(), timeout_seconds=10, environment=os.environ
        )
        self.assertTrue(result["passed"])
        self.assertEqual(result["exit_code"], 0)

    def test_failure_exit_is_not_relabelled(self) -> None:
        result = qa_runner.run_command(
            [sys.executable, "-c", "import sys; print('failed'); sys.exit(7)"],
            cwd=Path.cwd(), timeout_seconds=10, environment=os.environ
        )
        self.assertFalse(result["passed"])
        self.assertEqual(result["exit_code"], 7)

    def test_timeout_is_failure(self) -> None:
        result = qa_runner.run_command(
            [sys.executable, "-c", "import time; time.sleep(1)"],
            cwd=Path.cwd(), timeout_seconds=0.01, environment=os.environ
        )
        self.assertFalse(result["passed"])
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["exit_code"], 124)

    def test_large_output_is_bounded(self) -> None:
        result = qa_runner.run_command(
            [sys.executable, "-c", "print('safe'); print('x' * 3000000)"],
            cwd=Path.cwd(), timeout_seconds=10, environment=os.environ,
        )
        self.assertTrue(result["passed"])
        self.assertTrue(result["output_truncated"])
        self.assertLess(len(result["output"]), qa_runner.MAX_OUTPUT_BYTES + 100)

    def test_timeout_stops_descendant(self) -> None:
        import time
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "child-survived"
            child = f"import time; time.sleep(0.8); open({str(marker)!r}, 'w').write('bad')"
            parent = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(10)"
            result = qa_runner.run_command(
                [sys.executable, "-c", parent], cwd=Path.cwd(),
                timeout_seconds=0.2, environment=os.environ,
            )
            self.assertTrue(result["timed_out"])
            time.sleep(1)
            self.assertFalse(marker.exists())

    def test_no_ai_when_disabled(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "README.md").write_text("synthetic", encoding="utf-8")
            suite = qa_runner.Suite(
                name="synthetic", description="failure", commands=((sys.executable, "-c", "raise SystemExit(3)"),),
                timeout_seconds=10, ai_on_failure=True, model_role="coder"
            )
            code, report_path, report = qa_runner.run_suite(
                suite, repo=root, report_root=root / "reports", use_ai=False,
                models_path=LOCAL_AI_DIR / "config" / "models.json",
                policy_path=LOCAL_AI_DIR / "config" / "policy.json", endpoint=None
            )
            self.assertEqual(code, 1)
            self.assertFalse(report["passed"])
            self.assertFalse(report["ai_called"])
            self.assertTrue(report_path.exists())

    def test_stops_after_first_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "README.md").write_text("synthetic", encoding="utf-8")
            marker = root / "must-not-exist"
            suite = qa_runner.Suite(
                name="stop", description="stop",
                commands=((sys.executable, "-c", "raise SystemExit(1)"),
                          (sys.executable, "-c", f"open({str(marker)!r}, 'w').write('bad')")),
                timeout_seconds=10, ai_on_failure=False, model_role="coder"
            )
            code, _, report = qa_runner.run_suite(
                suite, repo=root, report_root=root / "reports", use_ai=False,
                models_path=LOCAL_AI_DIR / "config" / "models.json",
                policy_path=LOCAL_AI_DIR / "config" / "policy.json", endpoint=None
            )
            self.assertEqual(code, 1)
            self.assertEqual(report["commands_executed"], 1)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
