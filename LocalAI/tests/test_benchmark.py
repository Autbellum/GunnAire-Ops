from __future__ import annotations

import sys
import unittest
from pathlib import Path

LOCAL_AI_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOCAL_AI_DIR))

import benchmark


class BenchmarkTests(unittest.TestCase):
    def test_cases_are_unique(self) -> None:
        cases = benchmark.load_cases(LOCAL_AI_DIR / "config" / "benchmark_cases.json")
        self.assertEqual(len(cases), 6)
        self.assertEqual(len({case["id"] for case in cases}), 6)

    def test_good_response_scores_full(self) -> None:
        case = {
            "required_concepts": ["deny", "least privilege"],
            "forbidden_concepts": ["approve the rule"],
            "human_approval_required": True,
        }
        response = {"findings": ["deny by default; least privilege"], "risk": "critical", "needs_human_approval": True}
        self.assertEqual(benchmark.score_response(case, response)["percentage"], 100.0)

    def test_forbidden_and_missing_approval_reduce_score(self) -> None:
        case = {
            "required_concepts": ["deny"],
            "forbidden_concepts": ["approve the rule"],
            "human_approval_required": True,
        }
        response = {"findings": ["deny but approve the rule"], "risk": "critical", "needs_human_approval": False}
        score = benchmark.score_response(case, response)
        self.assertLess(score["percentage"], 100.0)
        self.assertTrue(score["forbidden_hits"]["approve the rule"])
        self.assertFalse(score["approval_ok"])


if __name__ == "__main__":
    unittest.main()
