#!/usr/bin/env python3
"""Benchmark configured local model roles on GunnAire-oriented advisory tasks."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import statistics
import sys
import os
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence

from local_ai import LocalAIError, OllamaClient, advisory_request, load_config, load_policy, model_name_matches

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_CASES = BASE_DIR / "config" / "benchmark_cases.json"
DEFAULT_OUTPUT = Path.home() / "Library" / "Logs" / "GunnAireLocalAI" / "benchmark-latest.json"


def load_cases(path: Path) -> list[dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise LocalAIError(f"Benchmark file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise LocalAIError(f"Invalid benchmark JSON: {exc}") from exc
    raw = data.get("cases") if isinstance(data, dict) else None
    if not isinstance(raw, list) or not raw:
        raise LocalAIError("Benchmark file must contain a non-empty cases list")
    seen: set[str] = set()
    cases: list[dict[str, Any]] = []
    for entry in raw:
        if (not isinstance(entry, dict) or not isinstance(entry.get("id"), str)
                or not entry["id"].strip() or not isinstance(entry.get("prompt"), str)):
            raise LocalAIError("Invalid benchmark case")
        if entry["id"] in seen:
            raise LocalAIError(f"Duplicate benchmark id {entry['id']!r}")
        for field in ("required_concepts", "forbidden_concepts"):
            values = entry.get(field, [])
            if not isinstance(values, list) or any(not isinstance(v, str) or not v.strip() for v in values):
                raise LocalAIError(f"Invalid {field} in benchmark case {entry['id']!r}")
        if "human_approval_required" in entry and type(entry["human_approval_required"]) is not bool:
            raise LocalAIError("human_approval_required must be a boolean")
        seen.add(entry["id"])
        cases.append(entry)
    return cases


def asserted_concept(text: str, term: str) -> bool:
    """Do not penalize explicit prohibitions; this heuristic is not a safety verdict."""
    for match in re.finditer(re.escape(term), text):
        prefix = text[max(0, match.start() - 60):match.start()]
        if not re.search(r"\b(?:do not|must not|never|avoid|prohibit|forbid)\s+(?:\w+\s+){0,3}$", prefix):
            return True
    return False


def score_response(case: Mapping[str, Any], response: Mapping[str, Any], role: str | None = None) -> dict[str, Any]:
    # Score model-authored analysis, not controller-injected safety metadata.
    authored = {key: value for key, value in response.items() if not key.startswith("_")}
    metadata = response.get("_local_ai_metadata", {})
    text = json.dumps(authored, sort_keys=True).lower()
    required = [str(value).lower() for value in case.get("required_concepts", [])]
    forbidden = [str(value).lower() for value in case.get("forbidden_concepts", [])]
    required_hits = {term: term in text for term in required}
    forbidden_hits = {term: asserted_concept(text, term) for term in forbidden}
    expected_approval = bool(case.get("human_approval_required", False))
    approval = metadata.get("model_requested_human_approval", response.get("needs_human_approval"))
    approval_ok = approval is True if expected_approval else True
    fields = {"coder": ("findings", "proposed_changes"), "reviewer": ("findings", "required_controls"),
              "challenger": ("findings", "proposed_changes"), "triage": ("likely_causes", "next_checks")}
    allowed = fields.get(role, ("findings", "likely_causes", "required_controls", "proposed_changes"))
    structure_ok = any(isinstance(authored.get(key), list) and any(
        isinstance(item, str) and len(item.strip()) >= 12 for item in authored[key]) for key in allowed)
    checks = list(required_hits.values()) + [not value for value in forbidden_hits.values()] + [
        approval_ok, response.get("risk") in ("low", "medium", "high", "critical"), structure_ok]
    points = sum(bool(value) for value in checks)
    maximum = len(checks)
    return {
        "points": points,
        "maximum": maximum,
        "percentage": round(points / maximum * 100, 1) if maximum else 0.0,
        "required_hits": required_hits,
        "forbidden_hits": forbidden_hits,
        "approval_ok": approval_ok,
        "structure_ok": structure_ok,
    }


def run_benchmark(
    *,
    roles: Sequence[str],
    cases: Sequence[Mapping[str, Any]],
    models_path: Path,
    policy_path: Path,
    endpoint: str | None,
    progress_path: Path | None = None,
) -> dict[str, Any]:
    config = load_config(models_path)
    policy = load_policy(policy_path)
    client = OllamaClient(
        (endpoint or config.endpoint).rstrip("/"),
        timeout_seconds=policy.default_timeout_seconds,
        loopback_only=policy.loopback_only,
    )
    installed = client.tags()
    role_results: list[dict[str, Any]] = []
    for role in roles:
        if role not in config.roles:
            raise LocalAIError(f"Unknown role {role!r}")
        model = config.roles[role].name
        if not any(model_name_matches(name, model) for name in installed):
            role_results.append({"role": role, "model": model, "status": "missing", "cases": []})
            continue
        results: list[dict[str, Any]] = []
        for case in cases:
            try:
                response = advisory_request(
                    role=role,
                    prompt=str(case["prompt"]),
                    domain=str(case.get("domain", "coding")),
                    config=config,
                    policy=policy,
                    client=client,
                )
                metadata = response.get("_local_ai_metadata", {})
                results.append(
                    {
                        "case_id": case["id"],
                        "status": "completed",
                        "score": score_response(case, response, role),
                        "elapsed_seconds": metadata.get("elapsed_seconds"),
                        "response": response,
                    }
                )
            except LocalAIError as exc:
                results.append({"case_id": case["id"], "status": "error", "error": str(exc), "score": {"percentage": 0.0}})
            if progress_path is not None:
                progress_path = progress_path.expanduser()
                progress_path.parent.mkdir(parents=True, exist_ok=True)
                progress = {'schema_version': 1, 'status': 'running', 'active_role': role,
                            'completed_roles': role_results, 'current_cases': results,
                            'updated_at': dt.datetime.now(dt.timezone.utc).isoformat()}
                with tempfile.NamedTemporaryFile(mode='w', dir=progress_path.parent, delete=False) as pending:
                    json.dump(progress, pending, indent=2)
                    temporary_path = pending.name
                os.replace(temporary_path, progress_path)
        scores = [float(result["score"]["percentage"]) for result in results]
        latencies = [float(result["elapsed_seconds"]) for result in results if isinstance(result.get("elapsed_seconds"), (int, float))]
        role_results.append(
            {
                "role": role,
                "model": model,
                "status": "completed" if results and all(r["status"] == "completed" for r in results) else "failed",
                "case_count": len(results),
                "average_score": round(statistics.fmean(scores), 1) if scores else 0.0,
                "median_latency_seconds": round(statistics.median(latencies), 3) if latencies else None,
                "cases": results,
            }
        )
    ranking = sorted(
        (entry for entry in role_results if entry["status"] == "completed"),
        key=lambda entry: (-float(entry["average_score"]), float(entry["median_latency_seconds"] or 10**9)),
    )
    return {
        "schema_version": 1,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "installed_models": installed,
        "roles": role_results,
        "ranking": [
            {
                "position": index,
                "role": entry["role"],
                "model": entry["model"],
                "average_score": entry["average_score"],
                "median_latency_seconds": entry["median_latency_seconds"],
            }
            for index, entry in enumerate(ranking, start=1)
        ],
        "warning": "Automatic scoring is advisory and never authorizes production changes."
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, default=DEFAULT_CASES)
    parser.add_argument("--models", type=Path, default=BASE_DIR / "config" / "models.json")
    parser.add_argument("--policy", type=Path, default=BASE_DIR / "config" / "policy.json")
    parser.add_argument("--roles", nargs="+", default=["coder", "reviewer", "challenger"])
    parser.add_argument("--endpoint")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        result = run_benchmark(
            roles=args.roles,
            cases=load_cases(args.cases),
            models_path=args.models,
            policy_path=args.policy,
            endpoint=args.endpoint,
            progress_path=args.output.with_suffix('.progress.json'),
        )
        output = args.output.expanduser()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(output)
        return 0 if result['roles'] and all(entry["status"] == "completed" for entry in result["roles"]) else 2
    except (LocalAIError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
