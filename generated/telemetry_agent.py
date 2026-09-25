#!/usr/bin/env python3
"""Summarize recent simulator logs without reproducing private log text.

Use --simulator UDID for a bounded three-minute app and SpringBoard capture,
or --input PATH for an existing log. With neither source, the report says that
evidence is insufficient. A short capture cannot certify later app behavior.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime
import io
from pathlib import Path
import re
import resource
import stat
import subprocess
import sys
import tempfile
import os


HERE = Path(__file__).resolve().parent
MAX_LOG_BYTES = 32 * 1024 * 1024
MAX_EVENTS_IN_REPORT = 8

STAMPED_LINE = re.compile(
    r"^(?P<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+"
    r"\S+\s+(?P<process>[^\[]+)\[\d+:[^\]]+\]"
)
APP_BUNDLE = re.compile(r"\bcom\.gunnaire\.businesssuite\b", re.IGNORECASE)
SYSTEM_EXIT = re.compile(r"\b(?:FBProcessExit|RBSProcessExit(?:Context|Status)|Process exited:)\b", re.IGNORECASE)
FATAL_EXIT = re.compile(
    r"\b(?:crash|crashed|SIGTRAP|SIGABRT|SIGSEGV|EXC_BAD_ACCESS|EXC_CRASH|"
    r"watchdog|0x8badf00d)\b",
    re.IGNORECASE,
)
ENTITLEMENT_TRAP = re.compile(
    r"Significant issue at CKContainer\b[^\n]*\bmust have\b[^\n]*\bentitlement\b",
    re.IGNORECASE,
)
MAX_RECORD_CHARS = 16_384
SIMULATOR_ID = re.compile(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\Z")
LAUNCH_TIME = re.compile(
    r"\bPerformance event:\s*(?:(?P<slow>slowLaunch)\s+Launch took|launch\s+Launched in)\s+"
    r"(?P<value>\d+(?:\.\d+)?)\s*(?P<unit>milliseconds?|ms|seconds?|s)\b",
    re.IGNORECASE,
)
RECORDER_STALL = re.compile(
    r"\bPerformance event:\s*stall\s+[^\n]*\bfroze for\s+\d+(?:\.\d+)?\s+seconds?\b",
    re.IGNORECASE,
)
MAIN_CONTEXT = re.compile(r"\b(?:main[ -]?thread|main[ -]?actor|thread\s*1)\b", re.IGNORECASE)
STALL = re.compile(
    r"\b(?:hang|hanging|hung|stall|stalled|stalling|blocked|unresponsive|"
    r"not responding|frozen|freeze|deadlock)\b",
    re.IGNORECASE,
)
NEGATED_STALL = re.compile(
    r"\b(?:no|not|without|never)\s+(?:\w+\s+){0,3}"
    r"(?:hang|hanging|hung|stall|stalled|stalling|blocked|unresponsive|"
    r"frozen|freeze|deadlock)\b",
    re.IGNORECASE,
)
WATCHDOG = re.compile(
    r"\bwatchdog\b.{0,100}\b(?:kill|killed|terminat(?:e|ed|ion)|"
    r"exceeded|hang|hung|stall(?:ed)?|timed? out|timeout)\b|\b0x8badf00d\b",
    re.IGNORECASE,
)
CRASH = re.compile(
    r"\b(?:fatal error|uncaught exception|EXC_BAD_ACCESS|SIGABRT|"
    r"process crashed|application crashed|crash detected)\b",
    re.IGNORECASE,
)


@dataclass
class Finding:
    category: str
    stamp: str
    line_number: int


@dataclass
class Analysis:
    state: str = "insufficient"
    reason: str = "No capture was analyzed."
    captured_lines: int = 0
    app_lines: int = 0
    first_stamp: datetime | None = None
    last_stamp: datetime | None = None
    launch_seconds: list[float] = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)


def classify(message: str) -> str | None:
    """Return a specific signal, ignoring broad words in benign framework logs."""
    if RECORDER_STALL.search(message):
        return "App-reported main-thread stall"
    timing = LAUNCH_TIME.search(message)
    if timing is not None and timing.group("slow") is not None:
        return "App-reported slow launch"
    if ENTITLEMENT_TRAP.search(message):
        return "CloudKit entitlement trap signal"
    if CRASH.search(message):
        return "Crash signal"
    if WATCHDOG.search(message):
        return "Watchdog termination or timeout"
    if MAIN_CONTEXT.search(message) and STALL.search(message) and not NEGATED_STALL.search(message):
        return "Main-thread stall or hang signal"
    return None


def analyze(path: Path) -> Analysis:
    result = Analysis()

    def inspect_record(stamp_text: str, process: str, message: str, line_number: int) -> None:
        is_app = process.strip() == "GunnAire Ops"
        if is_app:
            result.app_lines += 1
        elif not (APP_BUNDLE.search(message) and SYSTEM_EXIT.search(message) and FATAL_EXIT.search(message)):
            return
        try:
            stamp = datetime.fromisoformat(stamp_text)
        except ValueError:
            return
        if result.first_stamp is None or stamp < result.first_stamp:
            result.first_stamp = stamp
        if result.last_stamp is None or stamp > result.last_stamp:
            result.last_stamp = stamp
        if is_app:
            timing = LAUNCH_TIME.search(message)
            if timing is not None:
                seconds = float(timing.group("value"))
                if timing.group("unit").lower().startswith("m"):
                    seconds /= 1000
                result.launch_seconds.append(seconds)
            category = classify(message)
        else:
            category = "System-reported app process crash"
        if category is not None:
            result.findings.append(Finding(category, stamp_text, line_number))

    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            result.reason = "Capture must be a regular file."
            return result
        if metadata.st_size > MAX_LOG_BYTES:
            result.reason = "Capture exceeds the 32 MiB analysis limit; inspect it separately."
            return result
        # Recheck the opened object: a path may change after lstat. Nonblocking
        # opening prevents a replacement FIFO from waiting for a writer.
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as stream:
            opened_metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(opened_metadata.st_mode):
                result.reason = "Capture must be a regular file."
                return result
            if opened_metadata.st_size > MAX_LOG_BYTES:
                result.reason = "Capture exceeds the 32 MiB analysis limit; inspect it separately."
                return result
            captured = stream.read(MAX_LOG_BYTES + 1)
        if len(captured) > MAX_LOG_BYTES:
            result.reason = "Capture exceeds the 32 MiB analysis limit; inspect it separately."
            return result
        # Parse only a complete bounded read, never findings from a truncated
        # prefix that could hide later failures.
        record_stamp: str | None = None
        record_process = ""
        record_message = ""
        record_line_number = 0
        for line_number, line in enumerate(io.StringIO(captured.decode("utf-8", errors="replace")), 1):
            result.captured_lines += 1
            match = STAMPED_LINE.match(line)
            if match is not None:
                if record_stamp is not None:
                    inspect_record(record_stamp, record_process, record_message, record_line_number)
                record_stamp = match.group("stamp")
                record_process = match.group("process")
                record_message = line[match.end():MAX_RECORD_CHARS]
                record_line_number = line_number
            elif record_stamp is not None and len(record_message) < MAX_RECORD_CHARS:
                record_message += line[:MAX_RECORD_CHARS - len(record_message)]
        if record_stamp is not None:
            inspect_record(record_stamp, record_process, record_message, record_line_number)
    except FileNotFoundError:
        result.reason = "Launch capture is missing. Run the simulator capture first."
        return result
    except OSError:
        result.reason = "Launch capture could not be read."
        return result

    if result.captured_lines == 0:
        result.reason = "Launch capture is empty. No launch result can be inferred."
    elif result.findings:
        result.state = "issue-observed"
        result.reason = "Explicit performance or failure signals were observed in the capture."
    elif result.app_lines == 0:
        result.reason = "Capture contains no timestamped GunnAire Ops entries or app process-exit evidence."
    else:
        result.state = "limited-observation"
        result.reason = "No explicit stall, watchdog, or crash signal was found in the captured entries."
    return result


def render(result: Analysis) -> str:
    lines = [
        "# GunnAire Ops launch health",
        "",
        f"**Assessment:** {result.state.replace('-', ' ').capitalize()}. {result.reason}",
        "",
        f"**Capture:** {result.captured_lines} log lines; {result.app_lines} timestamped app entries.",
    ]
    if result.first_stamp is not None and result.last_stamp is not None:
        elapsed = max(0.0, (result.last_stamp - result.first_stamp).total_seconds())
        lines.append(
            "**Observed window:** "
            f"{result.first_stamp.isoformat(sep=' ', timespec='milliseconds')} to "
            f"{result.last_stamp.isoformat(sep=' ', timespec='milliseconds')} "
            f"({elapsed:.3f} s between first and last app entries)."
        )
    if result.launch_seconds:
        times = ", ".join(f"{value:.3f} s" for value in result.launch_seconds[:MAX_EVENTS_IN_REPORT])
        suffix = " (additional values omitted)" if len(result.launch_seconds) > MAX_EVENTS_IN_REPORT else ""
        lines.append(f"**App-reported launch time:** {times}{suffix}.")
    else:
        lines.append("**App-reported launch time:** unavailable in this capture.")
    lines += ["", "## Failure signals", ""]
    if result.findings:
        for finding in result.findings[:MAX_EVENTS_IN_REPORT]:
            lines.append(f"- {finding.category} at {finding.stamp} (capture line {finding.line_number}).")
        omitted = len(result.findings) - MAX_EVENTS_IN_REPORT
        if omitted > 0:
            lines.append(f"- {omitted} additional signal(s) omitted from this concise report.")
    elif result.state == "insufficient":
        lines.append("No app evidence was available for failure assessment.")
    else:
        lines.append("No explicit failure signal observed in the analyzed entries.")
    lines += [
        "",
        "This report covers only the simulator log capture. Process-exit crashes are detected when "
        "the capture includes system logs. A launch timing message does not prove the interface was "
        "responsive, and absence of a signal does not rule out an unlogged or later failure.",
        "Raw log messages are excluded to keep credentials and private data out of this report.",
        "",
    ]
    return "\n".join(lines)


def _limit_capture_file_size() -> None:
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_LOG_BYTES, MAX_LOG_BYTES))


def analyze_simulator(identifier: str) -> Analysis:
    """Fetch only recent app and related SpringBoard logs, with time/size caps."""
    if SIMULATOR_ID.fullmatch(identifier) is None:
        return Analysis(reason="Simulator identifier is invalid.")
    with tempfile.TemporaryDirectory(prefix="gunnaire-telemetry-") as directory:
        capture = Path(directory) / "simulator.log"
        command = [
            "xcrun", "simctl", "spawn", identifier, "log", "show",
            "--style", "compact", "--last", "3m", "--predicate",
            'process == "GunnAire Ops" OR (process == "SpringBoard" AND eventMessage CONTAINS[c] "com.gunnaire.businesssuite")',
        ]
        try:
            with capture.open("wb") as output:
                completed = subprocess.run(
                    command, stdout=output, stderr=subprocess.DEVNULL,
                    timeout=20, check=False, preexec_fn=_limit_capture_file_size,
                )
        except (OSError, subprocess.TimeoutExpired):
            return Analysis(reason="Recent simulator log capture failed or timed out.")
        if completed.returncode != 0:
            return Analysis(reason="Recent simulator log capture failed.")
        return analyze(capture)


def write_report(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=".telemetry-", delete=False
        ) as stream:
            temporary = stream.name
            os.fchmod(stream.fileno(), 0o600)
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--input", type=Path, help="Analyze an existing captured log")
    source.add_argument("--simulator", help="Capture the last three minutes from a simulator UDID")
    parser.add_argument("--output", type=Path, default=HERE / "telemetry_health.md")
    args = parser.parse_args(argv)
    if args.input is not None:
        result = analyze(args.input)
    elif args.simulator is not None:
        result = analyze_simulator(args.simulator)
    else:
        result = Analysis(reason="No capture selected. Use --input or --simulator for current evidence.")
    try:
        write_report(args.output, render(result))
    except OSError:
        print("Could not write telemetry report.", file=sys.stderr)
        return 2
    print(f"Telemetry assessment: {result.state}; report saved.")
    return {"limited-observation": 0, "issue-observed": 1, "insufficient": 2}[result.state]


if __name__ == "__main__":
    raise SystemExit(main())
