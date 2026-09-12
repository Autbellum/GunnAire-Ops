#!/usr/bin/env python3
"""Guarded local Ollama client for GunnAire engineering workflows.

This client is advisory only. It rejects non-loopback inference endpoints, redacts
common credentials and PII, bounds inputs, denies credential/signing files, and
never executes model output or changes a repository or production system.
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
    """Base error for guarded local inference."""


class PolicyError(LocalAIError):
    """A request violates a local policy."""


class OllamaError(LocalAIError):
    """Ollama is unavailable or returned an invalid response."""


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
    default_timeout_seconds: int
    denied_path_names: frozenset[str]
    denied_extensions: frozenset[str]
    sensitive_environment_fragments: tuple[str, ...]
    forbidden_model_authorities: tuple[str, ...]
    high_risk_domains: frozenset[str]


@dataclasses.dataclass(frozen=True)
class RedactionResult:
    text: str
    replacements: int
    digest: str


_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "private-key",
        re.compile(
            r"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----.*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----",
            re.IGNORECASE | re.DOTALL,
        ),
    ),
    ("bearer", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{12,}", re.IGNORECASE)),
    ("openai-key", re.compile(r"\bsk-[A-Za-z0-9_-]{16,}\b")),
    ("github-token", re.compile(r"\bgh(?:p|o|u|s|r)_[A-Za-z0-9]{20,}\b", re.IGNORECASE)),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    (
        "secret-assignment",
        re.compile(
            r"(?im)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|private[_-]?key|secret)\b['\"]?\s*[:=]\s*['\"]?([^\s,'\";]+)"
        ),
    ),
    ("credit-card", re.compile(r"(?<!\d)(?:\d[ -]*?){13,19}(?!\d)")),
    ("ssn", re.compile(r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)")),
    ("email", re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE)),
    ("phone", re.compile(r"(?<!\d)(?:\+?1[ .-]?)?(?:\(?\d{3}\)?[ .-]?)\d{3}[ .-]?\d{4}(?!\d)")),
)

_SYSTEM_PROMPTS: Mapping[str, str] = {
    "coder": (
        "You are a local advisory software-engineering model. Propose code and deterministic tests, but do not "
        "claim to apply code, run tests, merge, push, sign, deploy, charge a customer, change accounting, or change "
        "a firewall. Test exit codes are authoritative. Return one JSON object with keys summary, findings, "
        "proposed_changes, tests, risk, needs_human_approval, needs_hosted_review."
    ),
    "reviewer": (
        "You are an independent local reviewer for security, authorization, accounting, payments, CloudKit, "
        "networking, recovery, and release risk. Challenge assumptions. Never perform privileged actions. Return "
        "one JSON object with keys summary, findings, required_controls, tests, risk, needs_human_approval, "
        "needs_hosted_review."
    ),
    "challenger": (
        "You are an independent coding challenger. Produce an alternative analysis and identify weaknesses. Do not "
        "execute, merge, or deploy. Return one JSON object with keys summary, findings, alternative, tests, risk, "
        "needs_human_approval, needs_hosted_review."
    ),
    "triage": (
        "You are a fast local test-log triage model. Never reinterpret a nonzero exit code as success. Return one "
        "JSON object with keys summary, likely_causes, recommended_checks, risk, needs_human_approval, "
        "needs_hosted_review."
    ),
}


def _read_object(path: Path) -> dict[str, Any]:
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
    data = _read_object(path)
    raw_models = data.get("models")
    if not isinstance(raw_models, dict) or not raw_models:
        raise LocalAIError("models.json must define at least one model role")
    roles: dict[str, ModelRole] = {}
    for role, entry in raw_models.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
            raise LocalAIError(f"Invalid model role {role!r}")
        roles[str(role)] = ModelRole(
            role=str(role),
            name=entry["name"].strip(),
            required=bool(entry.get("required", False)),
            purpose=str(entry.get("purpose", "")),
        )
    return Config(
        endpoint=str(data.get("endpoint", "http://127.0.0.1:11434")).rstrip("/"),
        minimum_ollama_version=str(data.get("minimum_ollama_version", "0.0.0")),
        roles=roles,
        generation=dict(data.get("generation", {})),
    )


def load_policy(path: Path = DEFAULT_POLICY) -> Policy:
    data = _read_object(path)
    return Policy(
        loopback_only=bool(data.get("loopback_only", True)),
        max_prompt_characters=int(data.get("max_prompt_characters", 60000)),
        max_log_characters=int(data.get("max_log_characters", 45000)),
        default_timeout_seconds=int(data.get("default_timeout_seconds", 300)),
        denied_path_names=frozenset(str(value) for value in data.get("denied_path_names", [])),
        denied_extensions=frozenset(str(value).lower() for value in data.get("denied_extensions", [])),
        sensitive_environment_fragments=tuple(
            str(value).upper() for value in data.get("sensitive_environment_fragments", [])
        ),
        forbidden_model_authorities=tuple(str(value) for value in data.get("forbidden_model_authorities", [])),
        high_risk_domains=frozenset(str(value).lower() for value in data.get("high_risk_domains", [])),
    )


def ensure_loopback_endpoint(endpoint: str) -> None:
    parsed = urllib.parse.urlparse(endpoint)
    if parsed.scheme != "http" or not parsed.hostname:
        raise PolicyError("Local endpoint must be an http URL with a hostname")
    if parsed.username or parsed.password:
        raise PolicyError("Credentials must not be embedded in the local endpoint")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.port != 11434:
        raise PolicyError("Use the local Ollama origin on port 11434 without extra URL components")
    host = parsed.hostname
    if host.lower() == "localhost":
        addresses = {ipaddress.ip_address("127.0.0.1"), ipaddress.ip_address("::1")}
    else:
        try:
            addresses = {ipaddress.ip_address(host)}
        except ValueError:
            raise PolicyError("Use a literal loopback address or localhost; DNS aliases are not allowed") from None
    if not addresses or any(not address.is_loopback for address in addresses):
        raise PolicyError(f"Refusing non-loopback endpoint: {endpoint}")


def redact_text(text: str) -> RedactionResult:
    redacted = text
    replacements = 0
    for label, pattern in _PATTERNS:
        if label == "secret-assignment":
            def replacement(match: re.Match[str]) -> str:
                return f"{match.group(1)}=<REDACTED:{label}>"
            redacted, count = pattern.subn(replacement, redacted)
        else:
            redacted, count = pattern.subn(f"<REDACTED:{label}>", redacted)
        replacements += count
    digest = hashlib.sha256(redacted.encode("utf-8")).hexdigest()
    return RedactionResult(redacted, replacements, digest)


def truncate_middle(text: str, limit: int) -> str:
    if limit <= 0:
        raise ValueError("limit must be positive")
    if len(text) <= limit:
        return text
    marker = f"\n... <TRUNCATED {len(text) - limit} CHARACTERS> ...\n"
    remaining = max(0, limit - len(marker))
    if len(marker) >= limit:
        return marker[:limit]
    left = remaining // 2
    right = remaining - left
    return text[:left] + marker + (text[-right:] if right else "")


def validate_readable_path(path: Path, root: Path, policy: Policy) -> Path:
    resolved_root = root.expanduser().resolve(strict=True)
    resolved = path.expanduser().resolve(strict=True)
    try:
        resolved.relative_to(resolved_root)
    except ValueError as exc:
        raise PolicyError(f"Path is outside approved repository root: {resolved}") from exc
    if any(part.lower() in {name.lower() for name in policy.denied_path_names} for part in resolved.parts):
        raise PolicyError(f"Path contains a denied credential directory: {resolved}")
    if resolved.suffix.lower() in policy.denied_extensions:
        raise PolicyError(f"Credential/signing file extension is denied: {resolved.suffix}")
    if not resolved.is_file():
        raise PolicyError(f"Expected a regular file: {resolved}")
    return resolved


def scrub_environment(environment: Mapping[str, str], policy: Policy) -> dict[str, str]:
    clean: dict[str, str] = {}
    for key, value in environment.items():
        upper = key.upper()
        if any(fragment in upper for fragment in policy.sensitive_environment_fragments):
            continue
        clean[key] = value
    clean["GUNNAIRE_LOCAL_AI"] = "1"
    clean["GUNNAIRE_PROVIDER_WRITES_DISABLED"] = "1"
    return clean


def parse_json_object(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?\s*", "", stripped, count=1, flags=re.IGNORECASE)
        stripped = re.sub(r"\s*```$", "", stripped, count=1)
    try:
        value = json.loads(stripped)
        if isinstance(value, dict):
            return value
    except json.JSONDecodeError:
        pass
    decoder = json.JSONDecoder()
    for index, character in enumerate(stripped):
        if character != "{":
            continue
        try:
            value, _ = decoder.raw_decode(stripped[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise OllamaError("Model response did not contain a valid JSON object")


def model_name_matches(installed: str, requested: str) -> bool:
    if installed == requested:
        return True
    installed_base = installed.split(":", 1)[0]
    requested_base = requested.split(":", 1)[0]
    return installed_base == requested_base and (":" not in requested or requested.endswith(":latest"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise PolicyError("Local inference redirects are forbidden")


def version_at_least(actual: str, minimum: str) -> bool:
    def parts(value):
        if not isinstance(value, str) or re.fullmatch(r"\d+\.\d+\.\d+", value) is None:
            return None
        return tuple(int(x) for x in value.split("."))
    left, right = parts(actual), parts(minimum)
    return left is not None and right is not None and left >= right


class OllamaClient:
    def __init__(self, endpoint: str, *, timeout_seconds: int = 300, loopback_only: bool = True):
        self.endpoint = endpoint.rstrip("/")
        self.timeout_seconds = timeout_seconds
        if not loopback_only:
            raise PolicyError("Non-loopback inference is disabled")
        ensure_loopback_endpoint(self.endpoint)
        if urllib.parse.urlparse(self.endpoint).hostname == "localhost":
            self.endpoint = "http://127.0.0.1:11434"

    def _request(self, route: str, payload: Mapping[str, Any] | None = None) -> dict[str, Any]:
        url = self.endpoint + route
        if payload is None:
            request = urllib.request.Request(url, method="GET")
        else:
            request = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                method="POST",
                headers={"Content-Type": "application/json", "Accept": "application/json"},
            )
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            with opener.open(request, timeout=self.timeout_seconds) as response:
                body = response.read(1_048_577)
                if len(body) > 1_048_576:
                    raise OllamaError("Local response exceeds its size limit")
                raw = body.decode("utf-8")
        except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
            raise OllamaError(f"Local Ollama request failed: {exc}") from exc
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise OllamaError("Ollama returned invalid JSON") from exc
        if not isinstance(value, dict):
            raise OllamaError("Ollama returned an unexpected payload")
        return value

    def version(self) -> str:
        return self._request("/api/version").get("version", "")

    def tags(self) -> list[str]:
        payload = self._request("/api/tags")
        raw_models = payload.get("models", [])
        if not isinstance(raw_models, list):
            return []
        return sorted(
            entry["name"] for entry in raw_models
            if isinstance(entry, dict) and isinstance(entry.get("name"), str)
        )

    def chat(
        self,
        *,
        model: str,
        system_prompt: str,
        user_prompt: str,
        generation: Mapping[str, Any],
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        started = time.monotonic()
        response = self._request(
            "/api/chat",
            {
                "model": model,
                "stream": False,
                "format": "json",
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                "options": dict(generation),
            },
        )
        message = response.get("message")
        if not isinstance(message, dict) or not isinstance(message.get("content"), str):
            raise OllamaError("Ollama response is missing message.content")
        return parse_json_object(message["content"]), {
            "elapsed_seconds": round(time.monotonic() - started, 3),
            "model": response.get("model", model),
            "prompt_eval_count": response.get("prompt_eval_count"),
            "eval_count": response.get("eval_count"),
            "total_duration_ns": response.get("total_duration"),
        }


def advisory_request(
    *,
    role: str,
    prompt: str,
    domain: str,
    config: Config,
    policy: Policy,
    client: OllamaClient,
) -> dict[str, Any]:
    if role not in config.roles or role not in _SYSTEM_PROMPTS:
        raise PolicyError(f"Unknown model role {role!r}")
    redacted = redact_text(prompt)
    bounded = truncate_middle(redacted.text, policy.max_prompt_characters)
    high_risk = domain.lower() in policy.high_risk_domains
    system_prompt = _SYSTEM_PROMPTS[role] + (
        f"\nPolicy: advisory_only=true; domain={domain}; high_risk={str(high_risk).lower()}. "
        "For high-risk work set needs_human_approval=true."
    )
    result, metrics = client.chat(
        model=config.roles[role].name,
        system_prompt=system_prompt,
        user_prompt=bounded,
        generation=config.generation,
    )
    model_requested_approval = result.get("needs_human_approval") is True
    if high_risk:
        result["needs_human_approval"] = True
    result["_local_ai_metadata"] = {
        "role": role,
        "domain": domain,
        "redactions": redacted.replacements,
        "redacted_prompt_sha256": redacted.digest,
        "advisory_only": True,
        "model_requested_human_approval": model_requested_approval,
        **metrics,
    }
    return result


def doctor(config: Config, policy: Policy, client: OllamaClient) -> dict[str, Any]:
    installed = client.tags()
    version = client.version() if hasattr(client, "version") else ""
    supported = version_at_least(version, config.minimum_ollama_version)
    roles: dict[str, Any] = {}
    required_present = True
    for role, model in config.roles.items():
        present = any(model_name_matches(name, model.name) for name in installed)
        roles[role] = {
            "model": model.name,
            "required": model.required,
            "present": present,
            "purpose": model.purpose,
        }
        if model.required and not present:
            required_present = False
    return {
        "status": "missing-required-models" if not required_present else ("ok" if supported else "ollama-version-unsupported"),
        "ollama_version": version,
        "version_supported": supported,
        "endpoint": config.endpoint,
        "loopback_only": policy.loopback_only,
        "installed_models": installed,
        "roles": roles,
    }


def _emit(value: Mapping[str, Any], output: Path | None) -> None:
    rendered = json.dumps(value, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(rendered)
    else:
        output.expanduser().parent.mkdir(parents=True, exist_ok=True)
        output.expanduser().write_text(rendered, encoding="utf-8")
        print(output.expanduser())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, default=DEFAULT_MODELS)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--endpoint")
    sub = parser.add_subparsers(dest="command", required=True)
    doctor_parser = sub.add_parser("doctor")
    doctor_parser.add_argument("--output", type=Path)
    ask = sub.add_parser("ask")
    ask.add_argument("--role", choices=sorted(_SYSTEM_PROMPTS), required=True)
    ask.add_argument("--domain", default="coding")
    source = ask.add_mutually_exclusive_group(required=True)
    source.add_argument("--prompt")
    source.add_argument("--prompt-file", type=Path)
    ask.add_argument("--repo", type=Path, default=Path.cwd())
    ask.add_argument("--output", type=Path)
    redact = sub.add_parser("redact")
    redact.add_argument("--file", type=Path, required=True)
    redact.add_argument("--repo", type=Path, default=Path.cwd())
    redact.add_argument("--output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        config = load_config(args.models)
        policy = load_policy(args.policy)
        client = OllamaClient(
            (args.endpoint or config.endpoint).rstrip("/"),
            timeout_seconds=policy.default_timeout_seconds,
            loopback_only=policy.loopback_only,
        )
        if args.command == "doctor":
            result = doctor(config, policy, client)
            _emit(result, args.output)
            return 0 if result.get("status") == "ok" else 1
        elif args.command == "redact":
            source = validate_readable_path(args.file, args.repo, policy)
            result = redact_text(source.read_text(encoding="utf-8", errors="replace"))
            _emit(
                {
                    "source": str(source),
                    "replacements": result.replacements,
                    "sha256": result.digest,
                    "redacted_text": result.text,
                },
                args.output,
            )
        else:
            prompt = args.prompt
            if prompt is None:
                source = validate_readable_path(args.prompt_file, args.repo, policy)
                prompt = source.read_text(encoding="utf-8", errors="replace")
            _emit(
                advisory_request(
                    role=args.role,
                    prompt=prompt,
                    domain=args.domain,
                    config=config,
                    policy=policy,
                    client=client,
                ),
                args.output,
            )
        return 0
    except (LocalAIError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
