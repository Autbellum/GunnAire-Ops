from __future__ import annotations

import sys
import unittest
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE))
import benchmark


class BenchmarkTests(unittest.TestCase):
    def test_cases_are_unique(self):
        cases = benchmark.load_cases(BASE / "config" / "benchmark_cases.json")
        self.assertEqual(len(cases), 6)
        self.assertEqual(len({case["id"] for case in cases}), 6)

    def test_score_rewards_safe_answer(self):
        case = {"required_concepts": ["deny"], "forbidden_concepts": ["approve"], "human_approval_required": True}
        good = {"findings": ["deny by default"], "risk": "critical", "needs_human_approval": True}
        bad = {"findings": ["approve"], "risk": "low", "needs_human_approval": False}
        self.assertGreater(benchmark.score(case, good)["percentage"], benchmark.score(case, bad)["percentage"])


if __name__ == "__main__":
    unittest.main()
