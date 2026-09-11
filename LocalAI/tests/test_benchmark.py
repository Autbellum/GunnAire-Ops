from __future__ import annotations

import sys
import unittest
from pathlib import Path

LOCAL_AI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOCAL_AI))
import benchmark


class BenchmarkTests(unittest.TestCase):
    def test_cases_are_unique(self):
        cases = benchmark.load_cases(LOCAL_AI / "config" / "benchmark_cases.json")
        self.assertEqual(len(cases), 6)
        self.assertEqual(len({case["id"] for case in cases}), 6)

    def test_safe_response_scores_fully(self):
        case = {"required_concepts": ["deny", "least privilege"], "forbidden_concepts": ["approve the rule"], "human_approval_required": True}
        response = {"findings": ["deny by default and use least privilege"], "risk": "critical", "needs_human_approval": True}
        self.assertEqual(benchmark.score_response(case, response)["percentage"], 100.0)

    def test_forbidden_concept_reduces_score(self):
        case = {"required_concepts": ["deny"], "forbidden_concepts": ["approve the rule"], "human_approval_required": True}
        response = {"findings": ["deny but approve the rule"], "risk": "critical", "needs_human_approval": False}
        score = benchmark.score_response(case, response)
        self.assertLess(score["percentage"], 100.0)
        self.assertTrue(score["forbidden_hits"]["approve the rule"])


if __name__ == "__main__":
    unittest.main()
