#!/usr/bin/env python3
"""Deterministic test runner with optional loopback-only AI failure triage."""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

from local_ai import LocalAIError, OllamaClient, advisory_request, load_config, load_policy, redact_text, scrub_environment, truncate_middle

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_SUITES = BASE_DIR / "config" / "suites.json"
DEFAULT_REPORT_ROOT = Path.home() / "Library" / "Logs" / "GunnAireLocalAI" / "runs"


@dataclasses.dataclass(frozen=True)
class Suite:
    name: str
    description: str
    commands: tuple[tuple[str, ...], ...]
    timeout_seconds: int
    ai_on_failure: bool
    model_role: str


def load_suites(path: Path = DEFAULT_SUITES) -> dict[str, Suite]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        raise LocalAIError(f"Cannot load suites from {path}: {exc}") from exc
    values = raw.get("suites") if isinstance(raw, dict) else None
    if not isinstance(values, dict) or not values:
        raise LocalAIError("Suites file must contain a non-empty suites object")
    result: dict[str, Suite] = {}
    for name, entry in values.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("commands"), list):
            raise LocalAIError(f"Invalid suite: {name}")
        commands: list[tuple[str, ...]] = []
        for command in entry["commands"]:
            if not isinstance(command, list) or not command or any(not isinstance(token, str) or not token for token in command):
                raise LocalAIError(f"Invalid shell-free command in suite {name}")
            commands.append(tuple(command))
        result[name] = Suite(
            name=name,
            description=str(entry.get("description", "")),
            commands=tuple(commands),
            timeout_seconds=int(entry.get("timeout_seconds", 600)),
            ai_on_failure=bool(entry.get("ai_on_failure", True)),
            model_role=str(entry.get("model_role", "coder")),
        )
    return result


def run_command(command: Sequence[str], *, cwd: Path, timeout_seconds: int, environment: Mapping[str, str]) -> dict[str, Any]:
    started = dt.datetime.now(dt.timezone.utc)
    try:
        completed = subprocess.run(
            list(command), cwd=cwd, env=dict(environment), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
            timeout=timeout_seconds, shell=False, check=False,
        )
        exit_code, output, timed_out = completed.returncode, completed.stdout, False
    except subprocess.TimeoutExpired as exc:
        exit_code, output, timed_out = 124, (exc.stdout or "") + "\n<TIMEOUT>\n", True
    finished = dt.datetime.now(dt.timezone.utc)
    redacted = redact_text(output)
    return {
        "command": list(command),
        "started_at": started.isoformat().replace("+00:00", "Z"),
        "finished_at": finished.isoformat().replace("+00:00", "Z"),
        "duration_seconds": round((finished - started).total_seconds(), 3),
        "exit_code": exit_code,
        "timed_out": timed_out,
        "passed": exit_code == 0,
        "redactions": redacted.replacements,
        "output_sha256": redacted.sha256,
        "output": redacted.text,
    }


def _triage(suite: Suite, results: Sequence[Mapping[str, Any]], *, models: Path, policy_path: Path, endpoint: str | None) -> dict[str, Any]:
    config, policy = load_config(models), load_policy(policy_path)
    client = OllamaClient(endpoint or config.endpoint, policy.timeout_seconds, policy.loopback_only)
    sections: list[str] = []
    for item in results:
        if item.get("passed"):
            continue
        sections.append(
            "COMMAND: " + " ".join(item.get("command", [])) +
            f"\nEXIT_CODE: {item.get('exit_code')}\nTIMED_OUT: {item.get('timed_out')}\nOUTPUT:\n{item.get('output', '')}"
        )
    prompt = truncate_middle(
        f"Deterministic suite {suite.name!r} failed. Exit codes are authoritative. "
        "Identify likely causes and checks without claiming success or applying changes.\n\n" + "\n\n---\n\n".join(sections),
        policy.max_log_characters,
    )
    return advisory_request(role=suite.model_role, prompt=prompt, domain="testing", config=config, policy=policy, client=client)


def run_suite(
    suite: Suite, *, repo: Path, report_root: Path, use_ai: bool,
    models: Path, policy_path: Path, endpoint: str | None,
) -> tuple[int, Path, dict[str, Any]]:
    resolved = repo.expanduser().resolve(strict=True)
    if not (resolved / ".git").exists() and not (resolved / "README.md").exists():
        raise LocalAIError(f"Repository root does not look valid: {resolved}")
    policy = load_policy(policy_path)
    environment = scrub_environment(os.environ, policy)
    environment.update({
        "PYTHONDONTWRITEBYTECODE": "1",
        "GUNNAIRE_TEST_MODE": "1",
        "GUNNAIRE_ALLOW_PROVIDER_WRITES": "0",
        "GUNNAIRE_ALLOW_PRODUCTION_NETWORK": "0",
    })
    run_id = dt.datetime.now().strftime("%Y%m%d-%H%M%S") + f"-{suite.name}"
    run_dir = report_root.expanduser() / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    results: list[dict[str, Any]] = []
    for index, command in enumerate(suite.commands, 1):
        item = run_command(command, cwd=resolved, timeout_seconds=suite.timeout_seconds, environment=environment)
        results.append(item)
        (run_dir / f"command-{index}.log").write_text(item["output"], encoding="utf-8")
        if not item["passed"]:
            break
    passed = len(results) == len(suite.commands) and all(item["passed"] for item in results)
    report: dict[str, Any] = {
        "schema_version": 1,
        "suite": suite.name,
        "description": suite.description,
        "repo": str(resolved),
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "passed": passed,
        "commands_expected": len(suite.commands),
        "commands_executed": len(results),
        "results": [{key: value for key, value in item.items() if key != "output"} for item in results],
        "ai_called": False,
    }
    if not passed and use_ai and suite.ai_on_failure:
        try:
            report["local_ai_triage"] = _triage(suite, results, models=models, policy_path=policy_path, endpoint=endpoint)
            report["ai_called"] = True
        except LocalAIError as exc:
            report["local_ai_triage_error"] = str(exc)
    path = run_dir / "report.json"
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return (0 if passed else 1), path, report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suites", type=Path, default=DEFAULT_SUITES)
    parser.add_argument("--models", type=Path, default=BASE_DIR / "config" / "models.json")
    parser.add_argument("--policy", type=Path, default=BASE_DIR / "config" / "policy.json")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    run = commands.add_parser("run")
    run.add_argument("--suite", required=True)
    run.add_argument("--repo", type=Path, default=Path.cwd())
    run.add_argument("--report-root", type=Path, default=DEFAULT_REPORT_ROOT)
    run.add_argument("--no-ai", action="store_true")
    run.add_argument("--endpoint")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        suites = load_suites(args.suites)
        if args.command == "list":
            print(json.dumps({name: dataclasses.asdict(suite) for name, suite in sorted(suites.items())}, indent=2, default=list))
            return 0
        if args.suite not in suites:
            raise LocalAIError(f"Unknown suite {args.suite!r}")
        code, path, report = run_suite(
            suites[args.suite], repo=args.repo, report_root=args.report_root, use_ai=not args.no_ai,
            models=args.models, policy_path=args.policy, endpoint=args.endpoint,
        )
        print(json.dumps({"passed": report["passed"], "report": str(path)}, indent=2))
        return code
    except (LocalAIError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
