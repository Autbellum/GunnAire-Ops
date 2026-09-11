#!/usr/bin/env python3
"""Guarded local Ollama client for GunnAire engineering work.

The model is advisory only. This module does not execute model output, mutate a
repository, merge, deploy, sign, charge customers, alter accounting records, or
change a firewall. Production policy permits only a loopback Ollama endpoint.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import ipaddress
import json
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Mapping, Sequence

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_MODELS = BASE_DIR / "config" / "models.json"
DEFAULT_POLICY = BASE_DIR / "config" / "policy.json"


class LocalAIError(RuntimeError):
    pass


class PolicyError(LocalAIError):
    pass


class OllamaError(LocalAIError):
    pass


@dataclasses.dataclass(frozen=True)
class ModelRole:
    role: str
    name: str
    required: bool
    purpose: str


@dataclasses.dataclass(frozen=True)
class Config:
    endpoint: str
    minimum_ollama_version: str
    roles: Mapping[str, ModelRole]
    generation: Mapping[str, Any]


@dataclasses.dataclass(frozen=True)
class Policy:
    loopback_only: bool
    max_prompt_characters: int
    max_log_characters: int
    timeout_seconds: int
    denied_path_names: frozenset[str]
    denied_extensions: frozenset[str]
    sensitive_env_fragments: tuple[str, ...]
    high_risk_domains: frozenset[str]


@dataclasses.dataclass(frozen=True)
class Redaction:
    text: str
    replacements: int
    sha256: str


SECRET_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("private-key", re.compile(r"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----.*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----", re.I | re.S)),
    ("bearer", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{12,}", re.I)),
    ("openai-key", re.compile(r"\bsk-[A-Za-z0-9_-]{16,}\b")),
    ("github-token", re.compile(r"\bgh(?:p|o|u|s|r)_[A-Za-z0-9]{20,}\b", re.I)),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    ("secret-assignment", re.compile(r"(?im)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|private[_-]?key|secret)\b\s*[:=]\s*['\"]?([^\s,'\";]{6,})")),
    ("ssn", re.compile(r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)")),
    ("email", re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I)),
    ("phone", re.compile(r"(?<!\d)(?:\+?1[ .-]?)?(?:\(\d{3}\)|\d{3})[ .-]\d{3}[ .-]\d{4}(?!\d)")),
    ("payment-card-grouped", re.compile(r"(?<!\d)(?:\d{4}[ -]?){3}\d{4}(?!\d)")),
    ("payment-card-contiguous", re.compile(r"(?<!\d)\d{13,19}(?!\d)")),
)

SYSTEM_PROMPTS: Mapping[str, str] = {
    "coder": (
        "You are a local advisory software-engineering model. Propose changes and deterministic tests. "
        "Never claim to have run, applied, merged, pushed, signed, deployed, charged a customer, changed "
        "accounting records, or changed a firewall. Test process exit codes are authoritative. Return one JSON "
        "object with keys summary, findings, proposed_changes, tests, risk, needs_human_approval, needs_hosted_review."
    ),
    "reviewer": (
        "You are an independent local security and correctness reviewer. Challenge assumptions involving authorization, "
        "payments, accounting, CloudKit, networking, recovery, signing, and deployment. Never authorize privileged action. "
        "Return one JSON object with keys summary, findings, required_controls, tests, risk, needs_human_approval, needs_hosted_review."
    ),
    "challenger": (
        "You are an independent coding challenger. Produce a materially different analysis, identify weaknesses, and "
        "suggest deterministic tests. Do not execute or deploy. Return one JSON object with keys summary, findings, "
        "alternative, tests, risk, needs_human_approval, needs_hosted_review."
    ),
    "triage": (
        "You are a fast local failure-triage model. Never reinterpret a nonzero exit code as success. Return one JSON "
        "object with keys summary, likely_causes, recommended_checks, risk, needs_human_approval, needs_hosted_review."
    ),
}


def _load_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise LocalAIError(f"Configuration file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise LocalAIError(f"Invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise LocalAIError(f"Expected a JSON object in {path}")
    return value


def load_config(path: Path = DEFAULT_MODELS) -> Config:
    raw = _load_object(path)
    model_data = raw.get("models")
    if not isinstance(model_data, dict) or not model_data:
        raise LocalAIError("models.json must contain a non-empty models object")
    roles: dict[str, ModelRole] = {}
    for role, entry in model_data.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
            raise LocalAIError(f"Invalid model role: {role!r}")
        roles[role] = ModelRole(role, entry["name"], bool(entry.get("required")), str(entry.get("purpose", "")))
    return Config(
        endpoint=str(raw.get("endpoint", "http://127.0.0.1:11434")).rstrip("/"),
        minimum_ollama_version=str(raw.get("minimum_ollama_version", "0.0.0")),
        roles=roles,
        generation=dict(raw.get("generation", {})),
    )


def load_policy(path: Path = DEFAULT_POLICY) -> Policy:
    raw = _load_object(path)
    return Policy(
        loopback_only=bool(raw.get("loopback_only", True)),
        max_prompt_characters=int(raw.get("max_prompt_characters", 60000)),
        max_log_characters=int(raw.get("max_log_characters", 45000)),
        timeout_seconds=int(raw.get("default_timeout_seconds", 300)),
        denied_path_names=frozenset(map(str, raw.get("denied_path_names", []))),
        denied_extensions=frozenset(str(x).lower() for x in raw.get("denied_extensions", [])),
        sensitive_env_fragments=tuple(str(x).upper() for x in raw.get("sensitive_environment_fragments", [])),
        high_risk_domains=frozenset(str(x).lower() for x in raw.get("high_risk_domains", [])),
    )


def ensure_loopback_endpoint(endpoint: str) -> None:
    parsed = urllib.parse.urlparse(endpoint)
    if parsed.scheme != "http" or not parsed.hostname or parsed.username or parsed.password:
        raise PolicyError("Local model endpoint must be credential-free HTTP on loopback")
    if parsed.hostname.lower() == "localhost":
        addresses = {ipaddress.ip_address("127.0.0.1"), ipaddress.ip_address("::1")}
    else:
        try:
            addresses = {ipaddress.ip_address(parsed.hostname)}
        except ValueError:
            try:
                addresses = {ipaddress.ip_address(info[4][0]) for info in socket.getaddrinfo(parsed.hostname, None)}
            except socket.gaierror as exc:
                raise PolicyError(f"Cannot resolve endpoint host: {exc}") from exc
    if not addresses or any(not address.is_loopback for address in addresses):
        raise PolicyError(f"Refusing non-loopback Ollama endpoint: {endpoint}")


def redact_text(text: str) -> Redaction:
    redacted = text
    count = 0
    for label, pattern in SECRET_PATTERNS:
        if label == "secret-assignment":
            redacted, found = pattern.subn(lambda match: f"{match.group(1)}=<REDACTED:{label}>", redacted)
        else:
            redacted, found = pattern.subn(f"<REDACTED:{label}>", redacted)
        count += found
    return Redaction(redacted, count, hashlib.sha256(redacted.encode()).hexdigest())


def truncate_middle(text: str, limit: int) -> str:
    if limit <= 0:
        raise ValueError("limit must be positive")
    if len(text) <= limit:
        return text
    marker = f"\n... <TRUNCATED {len(text) - limit} CHARACTERS> ...\n"
    available = max(0, limit - len(marker))
    left = available // 2
    return text[:left] + marker + text[-(available - left):]


def validate_readable_path(path: Path, root: Path, policy: Policy) -> Path:
    resolved_root = root.expanduser().resolve(strict=True)
    resolved = path.expanduser().resolve(strict=True)
    try:
        resolved.relative_to(resolved_root)
    except ValueError as exc:
        raise PolicyError(f"Path is outside approved root: {resolved}") from exc
    if any(part in policy.denied_path_names for part in resolved.parts):
        raise PolicyError("Path contains a denied credential directory or filename")
    if resolved.suffix.lower() in policy.denied_extensions:
        raise PolicyError(f"Denied credential/signing extension: {resolved.suffix}")
    if not resolved.is_file():
        raise PolicyError(f"Expected a regular file: {resolved}")
    return resolved


def scrub_environment(environment: Mapping[str, str], policy: Policy) -> dict[str, str]:
    clean = {
        key: value for key, value in environment.items()
        if not any(fragment in key.upper() for fragment in policy.sensitive_env_fragments)
    }
    clean["GUNNAIRE_LOCAL_AI"] = "1"
    clean["GUNNAIRE_PROVIDER_WRITES_DISABLED"] = "1"
    return clean


def parse_json_object(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped, count=1, flags=re.I)
        stripped = re.sub(r"\s*```$", "", stripped, count=1)
    try:
        value = json.loads(stripped)
        if isinstance(value, dict):
            return value
    except json.JSONDecodeError:
        pass
    decoder = json.JSONDecoder()
    for index, char in enumerate(stripped):
        if char != "{":
            continue
        try:
            value, _ = decoder.raw_decode(stripped[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise OllamaError("Model response did not contain a JSON object")


class OllamaClient:
    def __init__(self, endpoint: str, timeout_seconds: int = 300, loopback_only: bool = True):
        self.endpoint = endpoint.rstrip("/")
        self.timeout_seconds = timeout_seconds
        if loopback_only:
            ensure_loopback_endpoint(self.endpoint)

    def _request(self, route: str, payload: Mapping[str, Any] | None = None) -> dict[str, Any]:
        url = self.endpoint + route
        if payload is None:
            request = urllib.request.Request(url, method="GET")
        else:
            request = urllib.request.Request(
                url,
                data=json.dumps(payload).encode(),
                method="POST",
                headers={"Content-Type": "application/json", "Accept": "application/json"},
            )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                result = json.loads(response.read().decode())
        except (urllib.error.URLError, TimeoutError, socket.timeout, json.JSONDecodeError) as exc:
            raise OllamaError(f"Local Ollama request failed: {exc}") from exc
        if not isinstance(result, dict):
            raise OllamaError("Unexpected Ollama payload")
        return result

    def tags(self) -> list[str]:
        result = self._request("/api/tags")
        models = result.get("models", [])
        return sorted(item["name"] for item in models if isinstance(item, dict) and isinstance(item.get("name"), str))

    def chat(self, *, model: str, system: str, prompt: str, options: Mapping[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
        started = time.monotonic()
        result = self._request("/api/chat", {
            "model": model,
            "stream": False,
            "format": "json",
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}],
            "options": dict(options),
        })
        message = result.get("message")
        if not isinstance(message, dict) or not isinstance(message.get("content"), str):
            raise OllamaError("Ollama response is missing message.content")
        return parse_json_object(message["content"]), {
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "model": result.get("model", model),
            "prompt_eval_count": result.get("prompt_eval_count"),
            "eval_count": result.get("eval_count"),
        }


def model_name_matches(installed: str, requested: str) -> bool:
    if installed == requested:
        return True
    return installed.split(":", 1)[0] == requested.split(":", 1)[0] and (":" not in requested or requested.endswith(":latest") or installed.endswith(":latest"))


def advisory_request(*, role: str, prompt: str, domain: str, config: Config, policy: Policy, client: OllamaClient) -> dict[str, Any]:
    if role not in config.roles or role not in SYSTEM_PROMPTS:
        raise PolicyError(f"Unknown model role: {role}")
    redaction = redact_text(prompt)
    bounded = truncate_middle(redaction.text, policy.max_prompt_characters)
    high_risk = domain.lower() in policy.high_risk_domains
    system = SYSTEM_PROMPTS[role] + f"\nPolicy domain={domain}; high_risk={str(high_risk).lower()}; output is advisory only."
    response, metrics = client.chat(model=config.roles[role].name, system=system, prompt=bounded, options=config.generation)
    if high_risk:
        response["needs_human_approval"] = True
    response["_local_ai_metadata"] = {
        "role": role,
        "domain": domain,
        "redactions": redaction.replacements,
        "redacted_prompt_sha256": redaction.sha256,
        "advisory_only": True,
        **metrics,
    }
    return response


def doctor(config: Config, policy: Policy, client: OllamaClient) -> dict[str, Any]:
    installed = client.tags()
    roles: dict[str, Any] = {}
    missing = False
    for name, role in config.roles.items():
        present = any(model_name_matches(item, role.name) for item in installed)
        roles[name] = {"model": role.name, "required": role.required, "present": present, "purpose": role.purpose}
        missing |= role.required and not present
    return {"status": "missing-required-models" if missing else "ok", "endpoint": config.endpoint, "installed_models": installed, "roles": roles}


def _write(value: Mapping[str, Any], output: Path | None) -> None:
    text = json.dumps(value, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(text)
    else:
        output.expanduser().parent.mkdir(parents=True, exist_ok=True)
        output.expanduser().write_text(text, encoding="utf-8")
        print(output.expanduser())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, default=DEFAULT_MODELS)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--endpoint")
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("doctor")
    p.add_argument("--output", type=Path)
    p = commands.add_parser("ask")
    p.add_argument("--role", choices=sorted(SYSTEM_PROMPTS), required=True)
    p.add_argument("--domain", default="coding")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--prompt")
    source.add_argument("--prompt-file", type=Path)
    p.add_argument("--repo", type=Path, default=Path.cwd())
    p.add_argument("--output", type=Path)
    p = commands.add_parser("redact")
    p.add_argument("--file", type=Path, required=True)
    p.add_argument("--repo", type=Path, default=Path.cwd())
    p.add_argument("--output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        config, policy = load_config(args.models), load_policy(args.policy)
        client = OllamaClient(args.endpoint or config.endpoint, policy.timeout_seconds, policy.loopback_only)
        if args.command == "doctor":
            _write(doctor(config, policy, client), args.output)
        elif args.command == "redact":
            path = validate_readable_path(args.file, args.repo, policy)
            result = redact_text(path.read_text(encoding="utf-8", errors="replace"))
            _write({"source": str(path), "replacements": result.replacements, "sha256": result.sha256, "redacted_text": result.text}, args.output)
        elif args.command == "ask":
            prompt = args.prompt
            if prompt is None:
                path = validate_readable_path(args.prompt_file, args.repo, policy)
                prompt = path.read_text(encoding="utf-8", errors="replace")
            _write(advisory_request(role=args.role, prompt=prompt, domain=args.domain, config=config, policy=policy, client=client), args.output)
        return 0
    except (LocalAIError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
