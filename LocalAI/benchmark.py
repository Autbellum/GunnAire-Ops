#!/usr/bin/env python3
"""Benchmark local model roles on bounded GunnAire advisory tasks."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

from local_ai import LocalAIError, OllamaClient, advisory_request, load_config, load_policy, model_matches

BASE = Path(__file__).resolve().parent
DEFAULT_CASES = BASE / "config" / "benchmark_cases.json"
DEFAULT_OUTPUT = Path.home() / "Library" / "Logs" / "GunnAireLocalAI" / "benchmark-latest.json"


def load_cases(path: Path) -> list[dict[str, Any]]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        raise LocalAIError(f"Cannot load benchmark cases: {exc}") from exc
    cases = raw.get("cases") if isinstance(raw, dict) else None
    if not isinstance(cases, list) or not cases:
        raise LocalAIError("Benchmark requires a non-empty cases list")
    ids = [case.get("id") for case in cases if isinstance(case, dict)]
    if len(ids) != len(cases) or len(set(ids)) != len(ids):
        raise LocalAIError("Benchmark case IDs must be unique")
    return cases


def flatten(value: Any) -> str:
    return value if isinstance(value, str) else json.dumps(value, sort_keys=True)


def score(case: Mapping[str, Any], response: Mapping[str, Any]) -> dict[str, Any]:
    text = flatten(response).lower()
    required = [str(v).lower() for v in case.get("required_concepts", [])]
    forbidden = [str(v).lower() for v in case.get("forbidden_concepts", [])]
    required_hits = {term: term in text for term in required}
    forbidden_hits = {term: term in text for term in forbidden}
    expected_approval = bool(case.get("human_approval_required", False))
    approval_ok = bool(response.get("needs_human_approval")) if expected_approval else True
    points = sum(2 for hit in required_hits.values() if hit)
    points += sum(2 for hit in forbidden_hits.values() if not hit)
    maximum = 2 * (len(required) + len(forbidden)) + 3
    points += int(approval_ok) + int("risk" in response)
    points += int(any(key in response for key in ("findings", "likely_causes", "required_controls")))
    return {
        "points": points,
        "maximum": maximum,
        "percentage": round(points / maximum * 100, 1) if maximum else 0,
        "required_hits": required_hits,
        "forbidden_hits": forbidden_hits,
        "approval_ok": approval_ok,
    }


def run(roles: Sequence[str], cases: Sequence[Mapping[str, Any]], models: Path, policy_path: Path, endpoint: str | None) -> dict[str, Any]:
    config = load_config(models)
    policy = load_policy(policy_path)
    client = OllamaClient(endpoint or config.endpoint, policy.timeout_seconds, policy.loopback_only)
    installed = client.tags()
    role_results: list[dict[str, Any]] = []
    for role in roles:
        if role not in config.models:
            raise LocalAIError(f"Unknown role: {role}")
        model = config.models[role].name
        if not any(model_matches(name, model) for name in installed):
            role_results.append({"role": role, "model": model, "status": "missing", "cases": []})
            continue
        entries = []
        for case in cases:
            try:
                response = advisory_request(role, str(case["prompt"]), str(case.get("domain", "coding")), config, policy, client)
                entries.append({
                    "case_id": case["id"], "status": "completed", "score": score(case, response),
                    "elapsed_seconds": response.get("_local_ai_metadata", {}).get("elapsed_seconds"),
                    "response": response,
                })
            except LocalAIError as exc:
                entries.append({"case_id": case["id"], "status": "error", "error": str(exc), "score": {"percentage": 0}})
        scores = [float(e["score"]["percentage"]) for e in entries if e["status"] == "completed"]
        latencies = [float(e["elapsed_seconds"]) for e in entries if isinstance(e.get("elapsed_seconds"), (int, float))]
        role_results.append({
            "role": role, "model": model, "status": "completed", "cases": entries,
            "average_score": round(statistics.fmean(scores), 1) if scores else 0,
            "median_latency_seconds": round(statistics.median(latencies), 3) if latencies else None,
        })
    ranked = sorted(
        [r for r in role_results if r["status"] == "completed"],
        key=lambda r: (-r["average_score"], r["median_latency_seconds"] or 10**9),
    )
    return {
        "schema_version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "installed_models": installed,
        "roles": role_results,
        "ranking": [
            {"position": i, "role": r["role"], "model": r["model"], "average_score": r["average_score"], "median_latency_seconds": r["median_latency_seconds"]}
            for i, r in enumerate(ranked, 1)
        ],
        "warning": "Automated scoring is advisory and does not authorize production changes."
    }


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cases", type=Path, default=DEFAULT_CASES)
    p.add_argument("--models", type=Path, default=BASE / "config" / "models.json")
    p.add_argument("--policy", type=Path, default=BASE / "config" / "policy.json")
    p.add_argument("--roles", nargs="+", default=["coder", "reviewer", "challenger"])
    p.add_argument("--endpoint")
    p.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        result = run(args.roles, load_cases(args.cases), args.models, args.policy, args.endpoint)
        args.output.expanduser().parent.mkdir(parents=True, exist_ok=True)
        args.output.expanduser().write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(args.output.expanduser())
        return 0 if any(r["status"] == "completed" for r in result["roles"]) else 2
    except (LocalAIError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
