#!/usr/bin/env python3
"""Run allowlisted deterministic tests, invoking local AI only after failure.

Commands are arrays, never shell strings. Child environments have likely provider
credentials removed. Test exit codes are authoritative; model output cannot turn a
failure into a pass or apply a change.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import selectors
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Mapping, Sequence

from local_ai import (
    LocalAIError,
    OllamaClient,
    PolicyError,
    advisory_request,
    load_config,
    load_policy,
    redact_text,
    scrub_environment,
    truncate_middle,
)

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_SUITES = BASE_DIR / "config" / "suites.json"
DEFAULT_REPORT_ROOT = Path.home() / "Library" / "Logs" / "GunnAireLocalAI" / "runs"
MAX_OUTPUT_BYTES = 1024 * 1024


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
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise LocalAIError(f"Suites file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise LocalAIError(f"Invalid suites JSON: {exc}") from exc
    raw = data.get("suites") if isinstance(data, dict) else None
    if not isinstance(raw, dict) or not raw:
        raise LocalAIError("Suites file must contain a suites object")
    result: dict[str, Suite] = {}
    for name, entry in raw.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("commands"), list) or not entry["commands"]:
            raise LocalAIError(f"Invalid suite {name!r}")
        timeout = entry.get("timeout_seconds", 600)
        if type(timeout) is not int or not 0 < timeout <= 86400:
            raise LocalAIError(f"Suite {name!r} requires an integer timeout between 1 and 86400")
        if "ai_on_failure" in entry and type(entry["ai_on_failure"]) is not bool:
            raise LocalAIError(f"Suite {name!r} requires a boolean ai_on_failure")
        commands: list[tuple[str, ...]] = []
        for command in entry["commands"]:
            if not isinstance(command, list) or not command or any(not isinstance(token, str) or not token for token in command):
                raise LocalAIError(f"Suite {name!r} contains an invalid command")
            commands.append(tuple(command))
        result[name] = Suite(
            name=name,
            description=str(entry.get("description", "")),
            commands=tuple(commands),
            timeout_seconds=timeout,
            ai_on_failure=bool(entry.get("ai_on_failure", True)),
            model_role=str(entry.get("model_role", "coder")),
        )
    return result


def run_command(
    command: Sequence[str],
    *,
    cwd: Path,
    timeout_seconds: int,
    environment: Mapping[str, str],
) -> dict[str, Any]:
    started = dt.datetime.now(dt.timezone.utc)
    captured = bytearray()
    output_truncated = False
    timed_out = False
    deadline = time.monotonic() + timeout_seconds
    with subprocess.Popen(
            list(command),
            cwd=cwd,
            env=dict(environment),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            shell=False,
            start_new_session=True,
        ) as process:
        assert process.stdout is not None
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map() or process.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    break
                for key, _ in selector.select(min(remaining, 0.1)):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    room = MAX_OUTPUT_BYTES - len(captured)
                    captured.extend(chunk[:room])
                    output_truncated |= len(chunk) > room
        exit_code = process.wait()
    if timed_out:
        exit_code = 124
    output = captured.decode("utf-8", errors="replace")
    if output_truncated:
        # Drop the final partial line before redaction so a clipped secret is not retained.
        output = output.rsplit("\n", 1)[0] if "\n" in output else ""
        output += "\n<OUTPUT TRUNCATED>\n"
    if timed_out:
        output += "\n<TIMEOUT>\n"
    finished = dt.datetime.now(dt.timezone.utc)
    redacted = redact_text(output)
    return {
        "command": list(command),
        "started_at": started.isoformat().replace("+00:00", "Z"),
        "finished_at": finished.isoformat().replace("+00:00", "Z"),
        "duration_seconds": round((finished - started).total_seconds(), 3),
        "exit_code": exit_code,
        "timed_out": timed_out,
        "output_truncated": output_truncated,
        "passed": exit_code == 0,
        "redactions": redacted.replacements,
        "output_sha256": redacted.digest,
        "output": redacted.text,
    }


def _triage(
    suite: Suite,
    results: Sequence[Mapping[str, Any]],
    *,
    models_path: Path,
    policy_path: Path,
    endpoint: str | None,
) -> dict[str, Any]:
    config = load_config(models_path)
    policy = load_policy(policy_path)
    client = OllamaClient(
        (endpoint or config.endpoint).rstrip("/"),
        timeout_seconds=policy.default_timeout_seconds,
        loopback_only=policy.loopback_only,
    )
    sections: list[str] = []
    for result in results:
        if result.get("passed"):
            continue
        sections.append(
            "COMMAND: " + " ".join(str(value) for value in result.get("command", [])) +
            f"\nEXIT_CODE: {result.get('exit_code')}\nTIMED_OUT: {result.get('timed_out')}" +
            "\nOUTPUT:\n" + str(result.get("output", ""))
        )
    prompt = (
        f"Deterministic suite {suite.name!r} failed. Exit codes are authoritative. "
        "Identify likely causes and safe checks. Do not claim success or apply changes.\n\n" +
        "\n\n---\n\n".join(sections)
    )
    return advisory_request(
        role=suite.model_role,
        prompt=truncate_middle(prompt, policy.max_log_characters),
        domain="testing",
        config=config,
        policy=policy,
        client=client,
    )


def run_suite(
    suite: Suite,
    *,
    repo: Path,
    report_root: Path,
    use_ai: bool,
    models_path: Path,
    policy_path: Path,
    endpoint: str | None,
) -> tuple[int, Path, dict[str, Any]]:
    resolved_repo = repo.expanduser().resolve(strict=True)
    if not (resolved_repo / ".git").exists() and not (resolved_repo / "README.md").exists():
        raise PolicyError(f"Repository root does not look valid: {resolved_repo}")
    policy = load_policy(policy_path)
    if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
        raise PolicyError("Guarded QA requires the macOS network sandbox; no unguarded fallback is permitted")
    environment = scrub_environment(os.environ, policy)
    environment.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "GUNNAIRE_TEST_MODE": "1",
            "GUNNAIRE_ALLOW_PROVIDER_WRITES": "0",
            "GUNNAIRE_ALLOW_PRODUCTION_NETWORK": "0",
        }
    )
    run_id = dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex
    run_dir = report_root.expanduser() / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    results: list[dict[str, Any]] = []
    network_policy = (
        '(version 1)(allow default)(deny network*)'
        '(allow network-inbound (local tcp "localhost:*"))'
        '(allow network-outbound (remote tcp "localhost:*"))'
    )
    for index, command in enumerate(suite.commands, start=1):
        guarded = ("/usr/bin/sandbox-exec", "-p", network_policy, *command)
        result = run_command(guarded, cwd=resolved_repo, timeout_seconds=suite.timeout_seconds, environment=environment)
        result["command"] = list(command)
        result["network_guard"] = "macOS sandbox: loopback TCP only"
        results.append(result)
        (run_dir / f"command-{index}.log").write_text(result["output"], encoding="utf-8")
        if not result["passed"]:
            break
    passed = len(results) == len(suite.commands) and all(result["passed"] for result in results)
    report: dict[str, Any] = {
        "schema_version": 1,
        "suite": suite.name,
        "description": suite.description,
        "repo": str(resolved_repo),
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "passed": passed,
        "commands_expected": len(suite.commands),
        "commands_executed": len(results),
        "results": [{key: value for key, value in result.items() if key != "output"} for result in results],
        "ai_called": False,
    }
    if not passed and use_ai and suite.ai_on_failure:
        try:
            report["local_ai_triage"] = _triage(
                suite,
                results,
                models_path=models_path,
                policy_path=policy_path,
                endpoint=endpoint,
            )
            report["ai_called"] = True
        except LocalAIError as exc:
            report["local_ai_triage_error"] = str(exc)
    report_path = run_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return (0 if passed else 1), report_path, report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suites", type=Path, default=DEFAULT_SUITES)
    parser.add_argument("--models", type=Path, default=BASE_DIR / "config" / "models.json")
    parser.add_argument("--policy", type=Path, default=BASE_DIR / "config" / "policy.json")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    run = sub.add_parser("run")
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
            print(json.dumps({name: dataclasses.asdict(suite) for name, suite in sorted(suites.items())}, indent=2))
            return 0
        if args.suite not in suites:
            raise LocalAIError(f"Unknown suite {args.suite!r}; use list")
        code, report_path, report = run_suite(
            suites[args.suite],
            repo=args.repo,
            report_root=args.report_root,
            use_ai=not args.no_ai,
            models_path=args.models,
            policy_path=args.policy,
            endpoint=args.endpoint,
        )
        print(json.dumps({"passed": report["passed"], "report": str(report_path)}, indent=2))
        return code
    except (LocalAIError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
