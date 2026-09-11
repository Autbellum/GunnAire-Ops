#!/usr/bin/env python3
"""Guarded local Ollama client for GunnAire engineering workflows.

The client is advisory only. It never executes model output, applies patches,
changes a firewall, or contacts a non-loopback model endpoint.
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
    name: str
    required: bool
    purpose: str


@dataclasses.dataclass(frozen=True)
class Config:
    endpoint: str
    minimum_ollama_version: str
    models: Mapping[str, ModelRole]
    generation: Mapping[str, Any]


@dataclasses.dataclass(frozen=True)
class Policy:
    loopback_only: bool
    max_prompt_characters: int
    max_log_characters: int
    timeout_seconds: int
    denied_path_names: frozenset[str]
    denied_extensions: frozenset[str]
    sensitive_environment_fragments: tuple[str, ...]
    high_risk_domains: frozenset[str]


@dataclasses.dataclass(frozen=True)
class Redaction:
    text: str
    replacements: int
    sha256: str


SECRET_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
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
    ("aws-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    (
        "secret-assignment",
        re.compile(
            r"(?im)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|private[_-]?key|secret)\b\s*[:=]\s*['\"]?([^\s,'\";]{6,})"
        ),
    ),
    ("credit-card", re.compile(r"(?<!\d)(?:\d[ -]*?){13,19}(?!\d)")),
    ("ssn", re.compile(r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)")),
    ("email", re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE)),
    ("phone", re.compile(r"(?<!\d)(?:\+?1[ .-]?)?(?:\(?\d{3}\)?[ .-]?)\d{3}[ .-]?\d{4}(?!\d)")),
)

SYSTEM_PROMPTS: Mapping[str, str] = {
    "coder": (
        "You are a local advisory software-engineering model. Propose changes and deterministic tests. "
        "Never claim to have applied code, passed a failing test, merged, pushed, signed, deployed, "
        "charged a customer, changed accounting records, or changed a firewall. Return one JSON object "
        "with keys summary, findings, proposed_changes, tests, risk, needs_human_approval, needs_hosted_review."
    ),
    "reviewer": (
        "You are an independent local security and correctness reviewer. Challenge assumptions involving "
        "authorization, accounting, payments, CloudKit, networking and deployment. Do not perform privileged "
        "actions. Return one JSON object with keys summary, findings, required_controls, tests, risk, "
        "needs_human_approval, needs_hosted_review."
    ),
    "challenger": (
        "You are an independent coding challenger. Provide an alternative analysis and identify weaknesses. "
        "Do not execute or deploy anything. Return one JSON object with keys summary, findings, alternative, "
        "tests, risk, needs_human_approval, needs_hosted_review."
    ),
    "triage": (
        "You are a fast local test-log triage model. A nonzero exit code is failure and cannot be relabeled. "
        "Return one JSON object with keys summary, likely_causes, recommended_checks, risk, "
        "needs_human_approval, needs_hosted_review."
    ),
}


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise LocalAIError(f"Configuration not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise LocalAIError(f"Invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise LocalAIError(f"Expected an object in {path}")
    return value


def load_config(path: Path = DEFAULT_MODELS) -> Config:
    raw = read_json(path)
    raw_models = raw.get("models")
    if not isinstance(raw_models, dict) or not raw_models:
        raise LocalAIError("models.json requires a non-empty models object")
    models: dict[str, ModelRole] = {}
    for role, item in raw_models.items():
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            raise LocalAIError(f"Invalid model role: {role}")
        models[str(role)] = ModelRole(
            name=item["name"].strip(),
            required=bool(item.get("required", False)),
            purpose=str(item.get("purpose", "")),
        )
    return Config(
        endpoint=str(raw.get("endpoint", "http://127.0.0.1:11434")).rstrip("/"),
        minimum_ollama_version=str(raw.get("minimum_ollama_version", "0.0.0")),
        models=models,
        generation=dict(raw.get("generation", {})),
    )


def load_policy(path: Path = DEFAULT_POLICY) -> Policy:
    raw = read_json(path)
    return Policy(
        loopback_only=bool(raw.get("loopback_only", True)),
        max_prompt_characters=int(raw.get("max_prompt_characters", 60000)),
        max_log_characters=int(raw.get("max_log_characters", 45000)),
        timeout_seconds=int(raw.get("default_timeout_seconds", 300)),
        denied_path_names=frozenset(str(v) for v in raw.get("denied_path_names", [])),
        denied_extensions=frozenset(str(v).lower() for v in raw.get("denied_extensions", [])),
        sensitive_environment_fragments=tuple(str(v).upper() for v in raw.get("sensitive_environment_fragments", [])),
        high_risk_domains=frozenset(str(v).lower() for v in raw.get("high_risk_domains", [])),
    )


def ensure_loopback_endpoint(endpoint: str) -> None:
    """Accept only literal loopback addresses or the reserved localhost name.

    Custom hostnames that merely resolve to loopback are refused so DNS rebinding
    cannot redirect a later request to a LAN or internet address.
    """
    parsed = urllib.parse.urlparse(endpoint)
    if parsed.scheme != "http" or not parsed.hostname:
        raise PolicyError("Local model endpoint must use HTTP and include a host")
    if parsed.username or parsed.password:
        raise PolicyError("Credentials may not be embedded in the local model endpoint")
    if parsed.path not in ("", "/") or parsed.params or parsed.query or parsed.fragment:
        raise PolicyError("Local model endpoint must not include a path, query, or fragment")
    host = parsed.hostname.lower()
    if host == "localhost":
        return
    try:
        address = ipaddress.ip_address(host)
    except ValueError as exc:
        raise PolicyError("Local model endpoint host must be localhost or a literal loopback address") from exc
    if not address.is_loopback:
        raise PolicyError(f"Refusing non-loopback endpoint: {endpoint}")


def redact_text(text: str) -> Redaction:
    result = text
    replacements = 0
    for label, pattern in SECRET_PATTERNS:
        if label == "secret-assignment":
            result, count = pattern.subn(lambda m: f"{m.group(1)}=<REDACTED:{label}>", result)
        else:
            result, count = pattern.subn(f"<REDACTED:{label}>", result)
        replacements += count
    return Redaction(result, replacements, hashlib.sha256(result.encode("utf-8")).hexdigest())


def truncate_middle(text: str, limit: int) -> str:
    if limit <= 0:
        raise ValueError("limit must be positive")
    if len(text) <= limit:
        return text
    marker = f"\n... <TRUNCATED {len(text) - limit} CHARACTERS> ...\n"
    if len(marker) >= limit:
        return marker[:limit]
    available = limit - len(marker)
    left = available // 2
    right = available - left
    suffix = text[-right:] if right else ""
    return text[:left] + marker + suffix


def validate_path(path: Path, root: Path, policy: Policy) -> Path:
    resolved_root = root.expanduser().resolve(strict=True)
    resolved = path.expanduser().resolve(strict=True)
    try:
        resolved.relative_to(resolved_root)
    except ValueError as exc:
        raise PolicyError(f"Path is outside the approved repository: {resolved}") from exc
    denied_names = {name.casefold() for name in policy.denied_path_names}
    if any(part.casefold() in denied_names for part in resolved.parts):
        raise PolicyError(f"Denied path component in {resolved}")
    if resolved.suffix.lower() in policy.denied_extensions:
        raise PolicyError(f"Denied credential/signing extension: {resolved.suffix}")
    if not resolved.is_file():
        raise PolicyError(f"Expected a regular file: {resolved}")
    return resolved


def scrub_environment(environment: Mapping[str, str], policy: Policy) -> dict[str, str]:
    clean = {
        key: value
        for key, value in environment.items()
        if not any(fragment in key.upper() for fragment in policy.sensitive_environment_fragments)
    }
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


def model_matches(installed: str, requested: str) -> bool:
    if installed == requested:
        return True
    installed_base = installed.split(":", 1)[0]
    requested_base = requested.split(":", 1)[0]
    return installed_base == requested_base and (":" not in requested or requested.endswith(":latest") or installed.endswith(":latest"))


def version_at_least(installed: str | None, required: str) -> bool:
    if not installed:
        return False
    try:
        installed_parts = tuple(int(part) for part in installed.split(".")[:3])
        required_parts = tuple(int(part) for part in required.split(".")[:3])
    except ValueError:
        return False
    installed_parts += (0,) * (3 - len(installed_parts))
    required_parts += (0,) * (3 - len(required_parts))
    return installed_parts >= required_parts


class OllamaClient:
    def __init__(self, endpoint: str, timeout_seconds: int = 300, loopback_only: bool = True):
        self.endpoint = endpoint.rstrip("/")
        self.timeout_seconds = timeout_seconds
        if loopback_only:
            ensure_loopback_endpoint(self.endpoint)

    def request(self, route: str, payload: Mapping[str, Any] | None = None) -> dict[str, Any]:
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
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                raw = response.read().decode("utf-8")
        except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
            raise OllamaError(f"Local Ollama request failed: {exc}") from exc
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise OllamaError("Ollama returned invalid JSON") from exc
        if not isinstance(value, dict):
            raise OllamaError("Ollama returned an unexpected payload")
        return value

    def version(self) -> str | None:
        payload = self.request("/api/version")
        value = payload.get("version")
        return value if isinstance(value, str) and value.strip() else None

    def tags(self) -> list[str]:
        payload = self.request("/api/tags")
        models = payload.get("models", [])
        return sorted(
            item["name"]
            for item in models
            if isinstance(item, dict) and isinstance(item.get("name"), str)
        )

    def chat(self, model: str, system: str, user: str, options: Mapping[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
        started = time.monotonic()
        response = self.request(
            "/api/chat",
            {
                "model": model,
                "stream": False,
                "format": "json",
                "messages": [
                    {"role": "system", "content": system},
                    {"role": "user", "content": user},
                ],
                "options": dict(options),
            },
        )
        elapsed = time.monotonic() - started
        message = response.get("message")
        if not isinstance(message, dict) or not isinstance(message.get("content"), str):
            raise OllamaError("Ollama response is missing message.content")
        return parse_json_object(message["content"]), {
            "elapsed_seconds": round(elapsed, 3),
            "model": response.get("model", model),
            "prompt_eval_count": response.get("prompt_eval_count"),
            "eval_count": response.get("eval_count"),
        }


def advisory_request(role: str, prompt: str, domain: str, config: Config, policy: Policy, client: OllamaClient) -> dict[str, Any]:
    if role not in config.models or role not in SYSTEM_PROMPTS:
        raise PolicyError(f"Unknown model role: {role}")
    redaction = redact_text(prompt)
    bounded = truncate_middle(redaction.text, policy.max_prompt_characters)
    high_risk = domain.lower() in policy.high_risk_domains
    system = SYSTEM_PROMPTS[role] + (
        f"\nPolicy: domain={domain}; high_risk={str(high_risk).lower()}; output is advisory only. "
        "For high-risk work, needs_human_approval must be true."
    )
    result, metrics = client.chat(config.models[role].name, system, bounded, config.generation)
    if high_risk:
        result["needs_human_approval"] = True
    result["_local_ai_metadata"] = {
        "role": role,
        "domain": domain,
        "redactions": redaction.replacements,
        "redacted_prompt_sha256": redaction.sha256,
        "advisory_only": True,
        **metrics,
    }
    return result


def doctor(config: Config, policy: Policy, client: OllamaClient) -> dict[str, Any]:
    version = client.version()
    installed = client.tags()
    roles: dict[str, Any] = {}
    complete = True
    for role, model in config.models.items():
        present = any(model_matches(name, model.name) for name in installed)
        roles[role] = {"model": model.name, "required": model.required, "present": present, "purpose": model.purpose}
        if model.required and not present:
            complete = False
    version_ok = version_at_least(version, config.minimum_ollama_version)
    if complete and version_ok:
        status = "ok"
    elif not version_ok:
        status = "ollama-version-unsupported"
    else:
        status = "missing-required-models"
    return {
        "status": status,
        "endpoint": client.endpoint,
        "loopback_only": policy.loopback_only,
        "ollama_version": version,
        "minimum_ollama_version": config.minimum_ollama_version,
        "ollama_version_supported": version_ok,
        "installed_models": installed,
        "roles": roles,
    }


def emit(value: Mapping[str, Any], output: Path | None) -> None:
    rendered = json.dumps(value, indent=2, sort_keys=True) + "\n"
    if output is None:
        sys.stdout.write(rendered)
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8")
        print(output)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("--models", type=Path, default=DEFAULT_MODELS)
    root.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    root.add_argument("--endpoint")
    sub = root.add_subparsers(dest="command", required=True)
    p = sub.add_parser("doctor")
    p.add_argument("--output", type=Path)
    p = sub.add_parser("ask")
    p.add_argument("--role", choices=sorted(SYSTEM_PROMPTS), required=True)
    p.add_argument("--domain", default="coding")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--prompt")
    source.add_argument("--prompt-file", type=Path)
    p.add_argument("--repo", type=Path, default=Path.cwd())
    p.add_argument("--output", type=Path)
    p = sub.add_parser("redact")
    p.add_argument("--file", type=Path, required=True)
    p.add_argument("--repo", type=Path, default=Path.cwd())
    p.add_argument("--output", type=Path)
    return root


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        config = load_config(args.models)
        policy = load_policy(args.policy)
        client = OllamaClient(args.endpoint or config.endpoint, policy.timeout_seconds, policy.loopback_only)
        if args.command == "doctor":
            emit(doctor(config, policy, client), args.output)
        elif args.command == "redact":
            path = validate_path(args.file, args.repo, policy)
            value = redact_text(path.read_text(encoding="utf-8", errors="replace"))
            emit({"source": str(path), "replacements": value.replacements, "sha256": value.sha256, "redacted_text": value.text}, args.output)
        else:
            if args.prompt is not None:
                prompt = args.prompt
            else:
                path = validate_path(args.prompt_file, args.repo, policy)
                prompt = path.read_text(encoding="utf-8", errors="replace")
            emit(advisory_request(args.role, prompt, args.domain, config, policy, client), args.output)
        return 0
    except (LocalAIError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
