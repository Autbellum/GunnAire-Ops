#!/usr/bin/env python3
"""Bounded local-model benchmark for GunnAire coding and security tasks."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

from local_ai import LocalAIError, OllamaClient, advisory_request, load_config, load_policy, model_name_matches

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_CASES = BASE_DIR / "config" / "benchmark_cases.json"
DEFAULT_OUTPUT = Path.home() / "Library" / "Logs" / "GunnAireLocalAI" / "benchmark-latest.json"


def load_cases(path: Path) -> list[dict[str, Any]]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        raise LocalAIError(f"Cannot load benchmark cases: {exc}") from exc
    cases = raw.get("cases") if isinstance(raw, dict) else None
    if not isinstance(cases, list) or not cases:
        raise LocalAIError("Benchmark file must contain cases")
    seen: set[str] = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("id"), str) or not isinstance(case.get("prompt"), str):
            raise LocalAIError("Invalid benchmark case")
        if case["id"] in seen:
            raise LocalAIError(f"Duplicate benchmark id: {case['id']}")
        seen.add(case["id"])
    return cases


def score_response(case: Mapping[str, Any], response: Mapping[str, Any]) -> dict[str, Any]:
    text = json.dumps(response, sort_keys=True).lower()
    required = [str(value).lower() for value in case.get("required_concepts", [])]
    forbidden = [str(value).lower() for value in case.get("forbidden_concepts", [])]
    required_hits = {term: term in text for term in required}
    forbidden_hits = {term: term in text for term in forbidden}
    expected_approval = bool(case.get("human_approval_required"))
    approval_ok = bool(response.get("needs_human_approval")) if expected_approval else True
    points = 2 * sum(required_hits.values()) + 2 * sum(not value for value in forbidden_hits.values())
    maximum = 2 * (len(required) + len(forbidden))
    for condition in (approval_ok, "risk" in response, any(key in response for key in ("findings", "likely_causes", "required_controls"))):
        maximum += 1
        points += int(condition)
    return {
        "points": points, "maximum": maximum,
        "percentage": round(points / maximum * 100 if maximum else 0, 1),
        "required_hits": required_hits, "forbidden_hits": forbidden_hits, "approval_ok": approval_ok,
    }


def run_benchmark(*, roles: Sequence[str], cases: Sequence[Mapping[str, Any]], models: Path, policy_path: Path, endpoint: str | None) -> dict[str, Any]:
    config, policy = load_config(models), load_policy(policy_path)
    client = OllamaClient(endpoint or config.endpoint, policy.timeout_seconds, policy.loopback_only)
    installed = client.tags()
    summaries: list[dict[str, Any]] = []
    for role in roles:
        if role not in config.roles:
            raise LocalAIError(f"Unknown role: {role}")
        model = config.roles[role].name
        if not any(model_name_matches(item, model) for item in installed):
            summaries.append({"role": role, "model": model, "status": "missing", "cases": []})
            continue
        case_results: list[dict[str, Any]] = []
        for case in cases:
            try:
                response = advisory_request(role=role, prompt=case["prompt"], domain=str(case.get("domain", "coding")), config=config, policy=policy, client=client)
                case_results.append({
                    "case_id": case["id"], "status": "completed", "score": score_response(case, response),
                    "elapsed_seconds": response.get("_local_ai_metadata", {}).get("elapsed_seconds"), "response": response,
                })
            except LocalAIError as exc:
                case_results.append({"case_id": case["id"], "status": "error", "error": str(exc), "score": {"percentage": 0.0}})
        percentages = [float(item["score"]["percentage"]) for item in case_results if item["status"] == "completed"]
        latencies = [float(item["elapsed_seconds"]) for item in case_results if isinstance(item.get("elapsed_seconds"), (int, float))]
        summaries.append({
            "role": role, "model": model, "status": "completed", "case_count": len(case_results),
            "average_score": round(statistics.fmean(percentages), 1) if percentages else 0,
            "median_latency_seconds": round(statistics.median(latencies), 3) if latencies else None,
            "cases": case_results,
        })
    ranked = sorted((item for item in summaries if item["status"] == "completed"), key=lambda item: (-item["average_score"], item["median_latency_seconds"] or 10**9))
    return {
        "schema_version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "installed_models": installed,
        "roles": summaries,
        "ranking": [{"position": i, "role": item["role"], "model": item["model"], "average_score": item["average_score"], "median_latency_seconds": item["median_latency_seconds"]} for i, item in enumerate(ranked, 1)],
        "warning": "Automated scoring is advisory and does not authorize production changes.",
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, default=DEFAULT_CASES)
    parser.add_argument("--models", type=Path, default=BASE_DIR / "config" / "models.json")
    parser.add_argument("--policy", type=Path, default=BASE_DIR / "config" / "policy.json")
    parser.add_argument("--roles", nargs="+", default=["coder", "reviewer", "challenger"])
    parser.add_argument("--endpoint")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    try:
        result = run_benchmark(roles=args.roles, cases=load_cases(args.cases), models=args.models, policy_path=args.policy, endpoint=args.endpoint)
        args.output.expanduser().parent.mkdir(parents=True, exist_ok=True)
        args.output.expanduser().write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(args.output.expanduser())
        return 0 if any(item["status"] == "completed" for item in result["roles"]) else 2
    except (LocalAIError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
