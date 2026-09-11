#!/usr/bin/env python3
"""Audit GunnAire source for AI-provider routing and Stable Diffusion misuse.

The audit is deterministic. It does not call any model or external service.
Stable Diffusion is permitted only for image work. Business text/reasoning must
route through the guarded local Ollama gateway or remain deterministic.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable


STABLE_DIFFUSION_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"stable\s*diffusion", re.IGNORECASE),
    re.compile(r"stable[_-]?diffusion", re.IGNORECASE),
    re.compile(r"automatic\s*1111|automatic1111", re.IGNORECASE),
    re.compile(r"\bcomfyui\b", re.IGNORECASE),
    re.compile(r"/sdapi/v\d+/(?:txt2img|img2img)", re.IGNORECASE),
    re.compile(r"\b(?:txt2img|img2img)\b", re.IGNORECASE),
)

HOSTED_LLM_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"api\.openai\.com", re.IGNORECASE),
    re.compile(r"api\.anthropic\.com", re.IGNORECASE),
    re.compile(r"generativelanguage\.googleapis\.com", re.IGNORECASE),
    re.compile(r"openrouter\.ai", re.IGNORECASE),
    re.compile(r"\bOPENAI_API_KEY\b", re.IGNORECASE),
    re.compile(r"\bANTHROPIC_API_KEY\b", re.IGNORECASE),
    re.compile(r"\bGEMINI_API_KEY\b", re.IGNORECASE),
    re.compile(r"\bfrom\s+openai\s+import\b", re.IGNORECASE),
    re.compile(r"\bimport\s+OpenAI\b"),
    re.compile(r"\bAnthropic\s*\("),
    re.compile(r"\bGoogleGenerativeAI\b", re.IGNORECASE),
)

LOCAL_LLM_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"\b(?:127\.0\.0\.1|localhost):11434\b", re.IGNORECASE),
    re.compile(r"/api/(?:chat|generate|tags)\b", re.IGNORECASE),
    re.compile(r"\bollama\b", re.IGNORECASE),
)

CANDIDATE_TERMS: tuple[tuple[str, int, re.Pattern[str]], ...] = (
    ("summarize", 5, re.compile(r"\bsummari[sz](?:e|ed|ing|ation|ations)?\b", re.IGNORECASE)),
    ("draft", 4, re.compile(r"\bdraft(?:ed|ing|s)?\b", re.IGNORECASE)),
    ("recommend", 4, re.compile(r"\brecommend(?:ation|ations|ed|ing|s)?\b", re.IGNORECASE)),
    ("insight", 4, re.compile(r"\binsight(?:s)?\b", re.IGNORECASE)),
    ("classify", 4, re.compile(r"\bclassif(?:y|ies|ied|ication|ications)\b", re.IGNORECASE)),
    ("extract", 3, re.compile(r"\bextract(?:ion|ed|ing|s)?\b", re.IGNORECASE)),
    ("explain", 3, re.compile(r"\bexplain(?:ed|ing|s|ation)?\b", re.IGNORECASE)),
    ("narrative", 3, re.compile(r"\bnarrative(?:s)?\b", re.IGNORECASE)),
    ("suggest", 3, re.compile(r"\bsuggest(?:ion|ions|ed|ing|s)?\b", re.IGNORECASE)),
    ("analyze", 3, re.compile(r"\banaly[sz](?:e|ed|ing|is|es)\b", re.IGNORECASE)),
    ("triage", 3, re.compile(r"\btriage(?:d|s|ing)?\b", re.IGNORECASE)),
    ("forecast", 2, re.compile(r"\bforecast(?:ed|ing|s)?\b", re.IGNORECASE)),
    ("prioritize", 2, re.compile(r"\bprioriti[sz](?:e|ed|ing|ation|ations)?\b", re.IGNORECASE)),
)


@dataclass(frozen=True)
class Match:
    category: str
    path: str
    line: int
    excerpt: str
    runtime: bool
    test_or_fixture: bool
    allowed: bool
    reason: str


@dataclass(frozen=True)
class Violation:
    code: str
    path: str
    line: int
    message: str
    excerpt: str


def load_policy(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise SystemExit(f"Routing policy not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid routing policy JSON: {path}: {exc}") from exc
    if not isinstance(raw, dict):
        raise SystemExit("Routing policy root must be a JSON object")
    return raw


def normalized_relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def iter_text_files(root: Path, policy: dict[str, Any]) -> Iterable[Path]:
    enforcement = policy.get("enforcement", {})
    extensions = {str(value).lower() for value in enforcement.get("scan_extensions", [])}
    skipped = {str(value) for value in enforcement.get("skip_directories", [])}
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative_parts = path.relative_to(root).parts
        if any(part in skipped for part in relative_parts):
            continue
        if path.suffix.lower() not in extensions:
            continue
        yield path


def is_test_or_fixture(relative: str, policy: dict[str, Any]) -> bool:
    fragments = policy.get("enforcement", {}).get("test_path_fragments", [])
    padded = f"/{relative}"
    return any(str(fragment) in padded for fragment in fragments)


def is_runtime(relative: str, policy: dict[str, Any]) -> bool:
    extensions = {
        str(value).lower()
        for value in policy.get("enforcement", {}).get("runtime_source_extensions", [])
    }
    return Path(relative).suffix.lower() in extensions


def is_exempt(relative: str, policy: dict[str, Any]) -> bool:
    return relative in {
        str(value)
        for value in policy.get("enforcement", {}).get("scanner_exempt_paths", [])
    }


def path_has_prefix(relative: str, prefixes: Iterable[str]) -> bool:
    return any(relative.startswith(str(prefix)) for prefix in prefixes)


def first_pattern_match(line: str, patterns: Iterable[re.Pattern[str]]) -> bool:
    return any(pattern.search(line) is not None for pattern in patterns)


def excerpt(line: str, limit: int = 240) -> str:
    value = " ".join(line.strip().split())
    if len(value) <= limit:
        return value
    return value[: limit - 1] + "…"


def audit_repository(root: Path, policy: dict[str, Any], max_findings: int = 300) -> dict[str, Any]:
    root = root.resolve()
    enforcement = policy.get("enforcement", {})
    stable_allow_marker = str(enforcement.get("stable_diffusion_allow_marker", ""))
    hosted_allow_marker = str(enforcement.get("hosted_provider_allow_marker", ""))
    mobile_allow_marker = str(enforcement.get("direct_mobile_ollama_allow_marker", ""))
    image_prefixes = enforcement.get("stable_diffusion_allowed_path_prefixes", [])

    matches: list[Match] = []
    violations: list[Violation] = []
    candidate_scores: dict[str, int] = defaultdict(int)
    candidate_terms: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    candidate_samples: dict[str, list[dict[str, Any]]] = defaultdict(list)
    files_scanned = 0

    for path in iter_text_files(root, policy):
        relative = normalized_relative(path, root)
        exempt = is_exempt(relative, policy)
        runtime = is_runtime(relative, policy)
        test_or_fixture = is_test_or_fixture(relative, policy)
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        files_scanned += 1

        for line_number, line in enumerate(text.splitlines(), start=1):
            if first_pattern_match(line, STABLE_DIFFUSION_PATTERNS):
                allowed = (
                    exempt
                    or test_or_fixture
                    or path_has_prefix(relative, image_prefixes)
                    or (stable_allow_marker and stable_allow_marker in line)
                    or not runtime
                )
                reason = "image-provider path/marker or non-runtime documentation" if allowed else "Stable Diffusion is restricted to image work"
                matches.append(Match("stable_diffusion", relative, line_number, excerpt(line), runtime, test_or_fixture, allowed, reason))
                if not allowed:
                    violations.append(Violation(
                        "AI-SD-NONIMAGE",
                        relative,
                        line_number,
                        "Stable Diffusion reference in business/runtime code outside an approved image-provider path",
                        excerpt(line),
                    ))

            if first_pattern_match(line, HOSTED_LLM_PATTERNS):
                allowed = exempt or test_or_fixture or (hosted_allow_marker and hosted_allow_marker in line) or not runtime
                reason = "explicit marker/test/documentation" if allowed else "Direct hosted LLM usage bypasses the local-first gateway"
                matches.append(Match("hosted_llm", relative, line_number, excerpt(line), runtime, test_or_fixture, allowed, reason))
                if not allowed:
                    violations.append(Violation(
                        "AI-HOSTED-DIRECT",
                        relative,
                        line_number,
                        "Direct hosted LLM endpoint, SDK, or credential reference in runtime code",
                        excerpt(line),
                    ))

            if first_pattern_match(line, LOCAL_LLM_PATTERNS):
                direct_mobile = relative.startswith("GunnAire Ops/") and runtime
                allowed = exempt or test_or_fixture or not direct_mobile or (mobile_allow_marker and mobile_allow_marker in line)
                reason = "local tooling/backend use" if allowed else "Mobile clients must use the authenticated backend gateway"
                matches.append(Match("local_llm", relative, line_number, excerpt(line), runtime, test_or_fixture, allowed, reason))
                if direct_mobile and not allowed:
                    violations.append(Violation(
                        "AI-MOBILE-DIRECT-OLLAMA",
                        relative,
                        line_number,
                        "The iOS/macOS business app must not contact Ollama directly; use the authenticated backend gateway",
                        excerpt(line),
                    ))

            if runtime and not test_or_fixture and (
                relative.startswith("GunnAire Ops/") or relative.startswith("Backend/")
            ):
                for term_name, weight, pattern in CANDIDATE_TERMS:
                    count = len(pattern.findall(line))
                    if count:
                        candidate_scores[relative] += weight * count
                        candidate_terms[relative][term_name] += count
                        if len(candidate_samples[relative]) < 3:
                            candidate_samples[relative].append({
                                "line": line_number,
                                "term": term_name,
                                "excerpt": excerpt(line),
                            })

    candidate_files = [
        {
            "path": path,
            "score": score,
            "terms": dict(sorted(candidate_terms[path].items())),
            "samples": candidate_samples[path],
        }
        for path, score in sorted(candidate_scores.items(), key=lambda item: (-item[1], item[0]))
    ]

    limited_matches = matches[:max_findings]
    limited_violations = violations[:max_findings]
    counts = defaultdict(int)
    allowed_counts = defaultdict(int)
    for item in matches:
        counts[item.category] += 1
        if item.allowed:
            allowed_counts[item.category] += 1

    return {
        "schema_version": 1,
        "status": "pass" if not violations else "violations_found",
        "policy_name": policy.get("policy_name", "unnamed"),
        "root": str(root),
        "files_scanned": files_scanned,
        "counts": {
            "stable_diffusion_matches": counts["stable_diffusion"],
            "hosted_llm_matches": counts["hosted_llm"],
            "local_llm_matches": counts["local_llm"],
            "allowed_stable_diffusion_matches": allowed_counts["stable_diffusion"],
            "allowed_hosted_llm_matches": allowed_counts["hosted_llm"],
            "allowed_local_llm_matches": allowed_counts["local_llm"],
            "violations": len(violations),
            "candidate_files": len(candidate_files),
        },
        "violations": [asdict(item) for item in limited_violations],
        "provider_matches": [asdict(item) for item in limited_matches],
        "candidate_business_ai_files": candidate_files[:100],
        "truncated": len(matches) > max_findings or len(violations) > max_findings,
        "notes": [
            "Candidate files are review leads, not automatic instructions to replace deterministic business logic.",
            "Stable Diffusion remains allowed only for image generation/editing/visual asset prototyping.",
            "Mobile app code must use an authenticated backend gateway rather than contacting Ollama directly.",
            "No model or external service was called by this audit.",
        ],
    }


def human_summary(report: dict[str, Any]) -> str:
    counts = report["counts"]
    lines = [
        f"AI routing audit: {report['status']}",
        f"Files scanned: {report['files_scanned']}",
        f"Stable Diffusion matches: {counts['stable_diffusion_matches']}",
        f"Hosted LLM matches: {counts['hosted_llm_matches']}",
        f"Local LLM matches: {counts['local_llm_matches']}",
        f"Violations: {counts['violations']}",
        f"Candidate business-AI files: {counts['candidate_files']}",
    ]
    for violation in report["violations"]:
        lines.append(
            f"{violation['code']} {violation['path']}:{violation['line']} — {violation['message']}"
        )
    return "\n".join(lines)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--policy",
        type=Path,
        default=Path(__file__).resolve().parent / "config" / "routing_policy.json",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--max-findings", type=int, default=300)
    parser.add_argument("--strict", action="store_true", help="Exit nonzero when policy violations are found")
    parser.add_argument("--report-only", action="store_true", help="Always exit zero after producing the audit")
    parser.add_argument("--json", action="store_true", help="Print the full JSON report to stdout")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if args.strict and args.report_only:
        raise SystemExit("Choose either --strict or --report-only, not both")
    policy = load_policy(args.policy)
    report = audit_repository(args.root, policy, max_findings=max(1, args.max_findings))
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
    print(payload if args.json else human_summary(report))
    if args.strict and report["status"] != "pass":
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
