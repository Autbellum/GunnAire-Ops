#!/usr/bin/env python3
"""Run allowlisted tests locally; invoke local AI only after a redacted failure."""

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

from local_ai import (
    LocalAIError,
    OllamaClient,
    advisory_request,
    load_config,
    load_policy,
    redact_text,
    scrub_environment,
    truncate_middle,
)

BASE = Path(__file__).resolve().parent
DEFAULT_SUITES = BASE / "config" / "suites.json"
DEFAULT_REPORTS = Path.home() / "Library" / "Logs" / "GunnAireLocalAI" / "runs"


@dataclasses.dataclass(frozen=True)
class Suite:
    name: str
    description: str
    commands: tuple[tuple[str, ...], ...]
    timeout_seconds: int
    ai_on_failure: bool
    model_role: str


def load_suites(path: Path) -> dict[str, Suite]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        raise LocalAIError(f"Cannot load suites from {path}: {exc}") from exc
    data = raw.get("suites") if isinstance(raw, dict) else None
    if not isinstance(data, dict):
        raise LocalAIError("Suites file requires a suites object")
    result: dict[str, Suite] = {}
    for name, item in data.items():
        if not isinstance(item, dict) or not isinstance(item.get("commands"), list):
            raise LocalAIError(f"Invalid suite: {name}")
        commands: list[tuple[str, ...]] = []
        for command in item["commands"]:
            if not isinstance(command, list) or not command or any(not isinstance(token, str) or not token for token in command):
                raise LocalAIError(f"Invalid command in suite {name}")
            commands.append(tuple(command))
        result[name] = Suite(
            name=name,
            description=str(item.get("description", "")),
            commands=tuple(commands),
            timeout_seconds=int(item.get("timeout_seconds", 600)),
            ai_on_failure=bool(item.get("ai_on_failure", True)),
            model_role=str(item.get("model_role", "coder")),
        )
    return result


def run_command(command: Sequence[str], cwd: Path, timeout: int, environment: Mapping[str, str]) -> dict[str, Any]:
    started = dt.datetime.now(dt.timezone.utc)
    try:
        completed = subprocess.run(
            list(command),
            cwd=cwd,
            env=dict(environment),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=timeout,
            shell=False,
            check=False,
        )
        code, output, timed_out = completed.returncode, completed.stdout, False
    except subprocess.TimeoutExpired as exc:
        code = 124
        captured = exc.stdout or ""
        if isinstance(captured, bytes):
            captured = captured.decode("utf-8", errors="replace")
        output = captured + "\n<TIMEOUT>\n"
        timed_out = True
    ended = dt.datetime.now(dt.timezone.utc)
    redacted = redact_text(output)
    return {
        "command": list(command),
        "started_at": started.isoformat().replace("+00:00", "Z"),
        "finished_at": ended.isoformat().replace("+00:00", "Z"),
        "duration_seconds": round((ended - started).total_seconds(), 3),
        "exit_code": code,
        "passed": code == 0,
        "timed_out": timed_out,
        "redactions": redacted.replacements,
        "output_sha256": redacted.sha256,
        "output": redacted.text,
    }


def run_suite(
    suite: Suite,
    repo: Path,
    report_root: Path,
    use_ai: bool,
    models: Path,
    policy_path: Path,
    endpoint: str | None,
) -> tuple[int, Path, dict[str, Any]]:
    repo = repo.expanduser().resolve(strict=True)
    if not ((repo / ".git").exists() or (repo / "README.md").exists()):
        raise LocalAIError(f"Not a recognizable repository root: {repo}")
    policy = load_policy(policy_path)
    environment = scrub_environment(os.environ, policy)
    environment.update({
        "PYTHONDONTWRITEBYTECODE": "1",
        "GUNNAIRE_TEST_MODE": "1",
        "GUNNAIRE_ALLOW_PROVIDER_WRITES": "0",
        "GUNNAIRE_ALLOW_PRODUCTION_NETWORK": "0",
    })
    run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S-%fZ") + "-" + suite.name
    run_dir = report_root.expanduser() / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    results: list[dict[str, Any]] = []
    for index, command in enumerate(suite.commands, 1):
        result = run_command(command, repo, suite.timeout_seconds, environment)
        results.append(result)
        (run_dir / f"command-{index}.log").write_text(result["output"], encoding="utf-8")
        if not result["passed"]:
            break
    passed = len(results) == len(suite.commands) and all(item["passed"] for item in results)
    report: dict[str, Any] = {
        "schema_version": 1,
        "suite": suite.name,
        "description": suite.description,
        "repo": str(repo),
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "passed": passed,
        "commands_expected": len(suite.commands),
        "commands_executed": len(results),
        "results": [{k: v for k, v in item.items() if k != "output"} for item in results],
        "ai_called": False,
    }
    if not passed and use_ai and suite.ai_on_failure:
        try:
            config = load_config(models)
            client = OllamaClient(endpoint or config.endpoint, policy.timeout_seconds, policy.loopback_only)
            failures = []
            for item in results:
                if not item["passed"]:
                    failures.append(
                        f"COMMAND: {' '.join(item['command'])}\nEXIT_CODE: {item['exit_code']}\n"
                        f"TIMED_OUT: {item['timed_out']}\nOUTPUT:\n{item['output']}"
                    )
            prompt = truncate_middle(
                "Deterministic test failure. Exit codes are authoritative. Triage only; do not apply changes.\n\n"
                + "\n\n---\n\n".join(failures),
                policy.max_log_characters,
            )
            report["local_ai_triage"] = advisory_request(
                suite.model_role, prompt, "testing", config, policy, client
            )
            report["ai_called"] = True
        except LocalAIError as exc:
            report["local_ai_triage_error"] = str(exc)
    report_path = run_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return (0 if passed else 1), report_path, report


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--suites", type=Path, default=DEFAULT_SUITES)
    root.add_argument("--models", type=Path, default=BASE / "config" / "models.json")
    root.add_argument("--policy", type=Path, default=BASE / "config" / "policy.json")
    sub = root.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    p = sub.add_parser("run")
    p.add_argument("--suite", required=True)
    p.add_argument("--repo", type=Path, default=Path.cwd())
    p.add_argument("--report-root", type=Path, default=DEFAULT_REPORTS)
    p.add_argument("--no-ai", action="store_true")
    p.add_argument("--endpoint")
    return root


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        suites = load_suites(args.suites)
        if args.command == "list":
            print(json.dumps({name: dataclasses.asdict(suite) for name, suite in sorted(suites.items())}, indent=2))
            return 0
        if args.suite not in suites:
            raise LocalAIError(f"Unknown suite: {args.suite}")
        code, report_path, report = run_suite(
            suites[args.suite], args.repo, args.report_root, not args.no_ai,
            args.models, args.policy, args.endpoint,
        )
        print(json.dumps({"passed": report["passed"], "report": str(report_path)}, indent=2))
        return code
    except (LocalAIError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
