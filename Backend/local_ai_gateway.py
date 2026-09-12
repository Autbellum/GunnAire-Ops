#!/usr/bin/env python3
"""Local-first, advisory-only business AI gateway for GunnAire Ops.

Only loopback Ollama is supported. There is no hosted-model fallback. Stable
Diffusion is intentionally excluded because it is reserved for image work.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import os
import re
import threading
import time
import uuid
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from LocalAI.local_ai import (
    Config as ModelConfig,
    OllamaClient,
    OllamaError,
    Policy as LocalPolicy,
    PolicyError,
    ensure_loopback_endpoint,
    load_config,
    load_policy,
    model_name_matches,
    redact_text,
    truncate_middle,
)

ROOT = Path(__file__).resolve().parents[1]
MODELS_PATH = ROOT / "LocalAI/config/models.json"
LOCAL_POLICY_PATH = ROOT / "LocalAI/config/policy.json"
ROUTING_POLICY_PATH = ROOT / "LocalAI/config/routing_policy.json"


class GatewayError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


class Unavailable(GatewayError):
    pass


class InvalidRequest(GatewayError):
    pass


class Forbidden(GatewayError):
    pass


@dataclasses.dataclass(frozen=True)
class Settings:
    enabled: bool = True
    endpoint: str = "http://127.0.0.1:11434"
    timeout: int = 120
    max_input: int = 20_000
    max_context: int = 12_000
    cache_ttl: int = 3_600
    cache_entries: int = 128
    concurrency: int = 1
    status_ttl: int = 15

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "Settings":
        source = os.environ if env is None else env
        enabled = str(source.get("GUNNAIRE_LOCAL_AI_ENABLED", "1")).strip().lower() not in {
            "0", "false", "no", "off", "disabled",
        }
        endpoint = str(source.get("GUNNAIRE_OLLAMA_ENDPOINT", cls.endpoint)).strip().rstrip("/")
        ensure_loopback_endpoint(endpoint)

        def integer(name: str, default: int, low: int, high: int) -> int:
            try:
                return min(max(int(str(source.get(name, default))), low), high)
            except ValueError as exc:
                raise InvalidRequest("invalid_configuration", f"{name} must be an integer") from exc

        return cls(
            enabled=enabled,
            endpoint=endpoint,
            timeout=integer("GUNNAIRE_LOCAL_AI_TIMEOUT_SECONDS", 120, 5, 600),
            max_input=integer("GUNNAIRE_LOCAL_AI_MAX_INPUT_CHARACTERS", 20_000, 500, 60_000),
            max_context=integer("GUNNAIRE_LOCAL_AI_MAX_CONTEXT_CHARACTERS", 12_000, 500, 40_000),
            cache_ttl=integer("GUNNAIRE_LOCAL_AI_CACHE_TTL_SECONDS", 3_600, 0, 86_400),
            cache_entries=integer("GUNNAIRE_LOCAL_AI_CACHE_MAX_ENTRIES", 128, 0, 1_000),
            concurrency=integer("GUNNAIRE_LOCAL_AI_MAX_CONCURRENT", 1, 1, 4),
            status_ttl=integer("GUNNAIRE_LOCAL_AI_STATUS_CACHE_SECONDS", 15, 0, 300),
        )


@dataclasses.dataclass(frozen=True)
class Task:
    preferred_role: str
    roles: frozenset[str]
    required: frozenset[str]
    strings: frozenset[str]
    lists: frozenset[str]
    numbers: frozenset[str]
    limit: int
    prompt: str


ALL = frozenset({"Admin", "Accounting", "Dispatcher", "Field Technician", "Standard"})
OFFICE = frozenset({"Admin", "Accounting", "Dispatcher", "Standard"})
ADMIN = frozenset({"Admin"})

TASKS: Mapping[str, Task] = {
    "customer_email_draft": Task("coder", ALL, frozenset({"subject", "body"}), frozenset({"subject", "body"}), frozenset({"warnings"}), frozenset(), 12_000,
        "Draft a concise transactional HVAC customer email using only supplied verified facts and the optional deterministic baseline. Never invent dates, prices, diagnoses, warranties, promises, discounts, arrival times, or completed work. Return JSON: subject, body, warnings. It is a staff-reviewed draft, never a sent message."),
    "customer_text_draft": Task("triage", ALL, frozenset({"body"}), frozenset({"body"}), frozenset({"warnings"}), frozenset(), 2_400,
        "Draft a brief transactional HVAC customer text using only supplied verified facts. Never invent arrival times, prices, diagnoses, promises, or completed work. Return JSON: body, warnings. It is a staff-reviewed draft."),
    "operations_narrative": Task("coder", OFFICE, frozenset({"headline", "summary"}), frozenset({"headline", "summary"}), frozenset({"priorities", "warnings"}), frozenset(), 12_000,
        "Convert the supplied deterministic GunnAire operations snapshot into a plain-language management narrative. Counts and scores are authoritative and must not be recalculated or changed. Separate facts from review priorities. Return JSON: headline, summary, priorities, warnings."),
    "service_note_summary": Task("coder", ALL, frozenset({"summary"}), frozenset({"summary"}), frozenset({"observations", "follow_up", "warnings"}), frozenset(), 12_000,
        "Summarize HVAC service notes without adding any diagnosis, measurement, repair, recommendation, code result, or customer statement. Preserve uncertainty and contradictions. Return JSON: summary, observations, follow_up, warnings. Technician review is required."),
    "document_classification": Task("triage", OFFICE, frozenset({"document_type", "confidence", "reason"}), frozenset({"document_type", "reason"}), frozenset({"warnings"}), frozenset({"confidence"}), 4_000,
        "Conservatively classify the supplied business document excerpt. When evidence is insufficient, use document_type unknown and low confidence. Never infer payment credentials. Return JSON: document_type, confidence from 0 to 1, reason, warnings."),
    "estimate_scope_draft": Task("coder", frozenset({"Admin", "Dispatcher", "Standard"}), frozenset({"scope"}), frozenset({"scope"}), frozenset({"exclusions", "clarifications", "warnings"}), frozenset(), 18_000,
        "Draft an HVAC estimating scope using only supplied source-backed facts. Never create quantities, prices, equipment selections, code conclusions, field conditions, exclusions, or contract terms without evidence. Put uncertainty in clarifications. Return JSON: scope, exclusions, clarifications, warnings."),
    "failure_triage": Task("triage", ADMIN, frozenset({"summary"}), frozenset({"summary"}), frozenset({"likely_causes", "recommended_checks", "warnings"}), frozenset(), 12_000,
        "Triage a deterministic test or service failure. A nonzero exit code remains a failure. Never claim to run, fix, merge, deploy, or change production. Return JSON: summary, likely_causes, recommended_checks, warnings."),
    "security_review": Task("reviewer", ADMIN, frozenset({"summary"}), frozenset({"summary"}), frozenset({"findings", "required_controls", "tests", "warnings"}), frozenset(), 18_000,
        "Review the supplied redacted evidence for security risk. Never change infrastructure, credentials, authorization, payments, accounting, or production. Return JSON: summary, findings, required_controls, tests, warnings."),
}

SECRET_KEYS = re.compile(r"(?:authorization|bearer|passw|secret|token|api.?key|private.?key|client.?secret|card.?number|cvv|cvc|routing.?number|account.?number|bank.?account|ssn|social.?security)", re.I)
SECRET_TEXT: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("private_key", re.compile(r"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----", re.I)),
    ("bearer_token", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{12,}", re.I)),
    ("provider_key", re.compile(r"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b", re.I)),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    ("ssn", re.compile(r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)")),
    ("secret_assignment", re.compile(r"(?im)\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|private[_-]?key)\b['\"]?\s*[:=]\s*['\"]?[^\s,'\";]{1,}")),
)
CARD = re.compile(r"(?<!\d)(?:\d[ -]*?){13,19}(?!\d)")


def _luhn(digits: str) -> bool:
    if not 13 <= len(digits) <= 19 or len(set(digits)) == 1:
        return False
    total, parity = 0, len(digits) % 2
    for index, char in enumerate(digits):
        value = int(char)
        if index % 2 == parity:
            value = value * 2 - (9 if value > 4 else 0)
        total += value
    return total % 10 == 0


def _prohibited(text: str) -> str | None:
    for label, pattern in SECRET_TEXT:
        if pattern.search(text):
            return label
    for candidate in CARD.findall(text):
        if _luhn("".join(filter(str.isdigit, candidate))):
            return "payment_card"
    return None


def _string(value: Any, name: str, limit: int, required: bool = False) -> str:
    if value is None and not required:
        return ""
    if not isinstance(value, str):
        raise InvalidRequest("invalid_request", f"{name} must be text")
    value = value.strip()
    if required and not value:
        raise InvalidRequest("invalid_request", f"{name} is required")
    if len(value) > limit:
        raise InvalidRequest("request_too_large", f"{name} exceeds {limit} characters")
    if found := _prohibited(value):
        raise InvalidRequest("prohibited_sensitive_data", f"{name} contains prohibited {found} data")
    return value


def _clean(value: Any, depth: int = 0) -> Any:
    if depth > 5:
        raise InvalidRequest("context_too_deep", "AI context nesting is too deep")
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        if found := _prohibited(value):
            raise InvalidRequest("prohibited_sensitive_data", f"AI context contains prohibited {found} data")
        return value
    if isinstance(value, Mapping):
        if len(value) > 80:
            raise InvalidRequest("context_too_large", "AI context has too many fields")
        result: dict[str, Any] = {}
        for raw_key, item in value.items():
            key = str(raw_key).strip()
            if not key or len(key) > 100 or SECRET_KEYS.search(key):
                raise InvalidRequest("prohibited_context_key", f"AI context field {key!r} is prohibited")
            result[key] = _clean(item, depth + 1)
        return result
    if isinstance(value, Sequence) and not isinstance(value, (bytes, bytearray)):
        if len(value) > 100:
            raise InvalidRequest("context_too_large", "AI context has too many list items")
        return [_clean(item, depth + 1) for item in value]
    raise InvalidRequest("invalid_context_value", "AI context contains an unsupported value")


def _result(task: Task, raw: Mapping[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    string_limit = max(500, task.limit // max(1, len(task.strings)))
    for key in task.strings:
        value = raw.get(key)
        result[key] = truncate_middle(value.strip(), string_limit) if isinstance(value, str) and value.strip() else ""
    for key in task.lists:
        value = raw.get(key)
        values = [value] if isinstance(value, str) else value if isinstance(value, Sequence) else []
        result[key] = [truncate_middle(item.strip(), 1_200) for item in values if isinstance(item, str) and item.strip()][:20]
    for key in task.numbers:
        try:
            value = float(raw.get(key))
        except (TypeError, ValueError):
            value = 0.0
        result[key] = min(max(value, 0.0), 1.0)
    missing = sorted(key for key in task.required if result.get(key) is None or result.get(key) == "" or result.get(key) == [])
    if missing:
        raise Unavailable("invalid_model_response", f"Local model omitted required fields: {', '.join(missing)}")
    if len(json.dumps(result, ensure_ascii=False)) > task.limit:
        raise Unavailable("model_response_too_large", "Local model response exceeded the task limit")
    return result


@dataclasses.dataclass
class CacheEntry:
    at: float
    result: dict[str, Any]
    model: str
    redactions: int
    digest: str


class LocalAIGateway:
    def __init__(self, settings: Settings, models: ModelConfig, policy: LocalPolicy, routing: Mapping[str, Any], client: Any | None = None, clock: Callable[[], float] = time.monotonic) -> None:
        ensure_loopback_endpoint(settings.endpoint)
        self.settings, self.models, self.policy, self.routing = settings, models, policy, dict(routing)
        self.client = client or OllamaClient(settings.endpoint, timeout_seconds=settings.timeout, loopback_only=True)
        self.clock, self.gate = clock, threading.BoundedSemaphore(settings.concurrency)
        self.cache: OrderedDict[str, CacheEntry] = OrderedDict()
        self.cache_lock, self.status_lock = threading.Lock(), threading.Lock()
        self.status_value: tuple[float, dict[str, Any]] | None = None

    def _model(self, role: str) -> str:
        configured = self.models.roles.get(role)
        if configured is None or not configured.name:
            raise Unavailable("model_not_configured", f"No local model is configured for {role}")
        return configured.name

    @staticmethod
    def _roles(task: Task) -> tuple[str, ...]:
        if task.preferred_role == "reviewer":
            return ("reviewer",)
        if task.preferred_role == "triage":
            return ("triage", "coder", "challenger")
        return ("coder", "challenger", "reviewer")

    def _select(self, task: Task, installed: Sequence[str]) -> tuple[str, str] | None:
        for role in self._roles(task):
            try:
                model = self._model(role)
            except Unavailable:
                continue
            if any(model_name_matches(name, model) for name in installed):
                return role, model
        return None

    def status(self, force: bool = False) -> dict[str, Any]:
        now = self.clock()
        with self.status_lock:
            if not force and self.status_value and now - self.status_value[0] <= self.settings.status_ttl:
                return dict(self.status_value[1])
        base = {
            "enabled": self.settings.enabled, "provider": "ollama", "local": True,
            "endpointScope": "loopback", "hostedFallbackEnabled": False, "hostedCreditsUsed": 0,
            "stableDiffusionScope": "image-only", "supportedTasks": sorted(TASKS),
            "models": {role: item.name for role, item in sorted(self.models.roles.items())},
        }
        if not self.settings.enabled:
            value = {**base, "available": False, "status": "disabled", "installedModels": [], "taskModels": {}}
        else:
            try:
                installed = self.client.tags()
                task_models, unavailable = {}, []
                for name, task in sorted(TASKS.items()):
                    selected = self._select(task, installed)
                    if selected:
                        role, model = selected
                        task_models[name] = {"role": role, "model": model}
                    else:
                        unavailable.append(name)
                available = sorted(task_models)
                configured = {item.name for item in self.models.roles.values() if item.name}
                missing = sorted(model for model in configured if not any(model_name_matches(item, model) for item in installed))
                value = {
                    **base, "available": bool(available),
                    "status": "ready" if not unavailable else "partially-ready" if available else "missing-models",
                    "installedModels": installed, "missingModels": missing,
                    "availableTasks": available, "unavailableTasks": unavailable, "taskModels": task_models,
                }
            except (OllamaError, PolicyError, OSError, ValueError):
                value = {**base, "available": False, "status": "unavailable", "installedModels": [], "taskModels": {}}
        with self.status_lock:
            self.status_value = (now, dict(value))
        return value

    def _cached(self, key: str) -> CacheEntry | None:
        if self.settings.cache_ttl <= 0 or self.settings.cache_entries <= 0:
            return None
        now = self.clock()
        with self.cache_lock:
            for expired in [name for name, item in self.cache.items() if now - item.at > self.settings.cache_ttl]:
                self.cache.pop(expired, None)
            item = self.cache.get(key)
            if item:
                self.cache.move_to_end(key)
            return item

    def _remember(self, key: str, item: CacheEntry) -> None:
        if self.settings.cache_ttl <= 0 or self.settings.cache_entries <= 0:
            return
        with self.cache_lock:
            self.cache[key] = item
            self.cache.move_to_end(key)
            while len(self.cache) > self.settings.cache_entries:
                self.cache.popitem(last=False)

    def assist(self, payload: Mapping[str, Any], actor_role: str) -> dict[str, Any]:
        if not self.settings.enabled:
            raise Unavailable("local_ai_disabled", "Local AI is disabled on this backend")
        if not isinstance(payload, Mapping):
            raise InvalidRequest("invalid_request", "AI request body must be an object")
        name = _string(payload.get("task"), "task", 80, True)
        task = TASKS.get(name)
        if task is None:
            raise InvalidRequest("unsupported_task", f"Unsupported local AI task: {name}")
        if actor_role not in task.roles:
            raise Forbidden("role_not_allowed", "This business role may not use the requested AI task")
        text = _string(payload.get("input"), "input", self.settings.max_input, True)
        context, baseline = _clean(payload.get("context", {})), _clean(payload.get("baseline", {}))
        if not isinstance(context, Mapping) or not isinstance(baseline, Mapping):
            raise InvalidRequest("invalid_request", "context and baseline must be objects")
        context_json = json.dumps(context, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        baseline_json = json.dumps(baseline, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        if len(context_json) + len(baseline_json) > self.settings.max_context:
            raise InvalidRequest("context_too_large", "AI context exceeds the configured limit")
        prompt = f"TASK: {name}\nVERIFIED INPUT:\n{text}\n\nSTRUCTURED CONTEXT:\n{context_json}\n\nOPTIONAL DETERMINISTIC BASELINE:\n{baseline_json}\n"
        redacted = redact_text(prompt)
        prompt = truncate_middle(redacted.text, self.policy.max_prompt_characters)
        status = self.status()
        selected = status.get("taskModels", {}).get(name) if isinstance(status.get("taskModels"), Mapping) else None
        if not isinstance(selected, Mapping):
            raise Unavailable("local_ai_unavailable", "No installed local model can serve this task")
        role, model = str(selected.get("role")), str(selected.get("model"))
        key = hashlib.sha256(json.dumps({"v": 1, "task": name, "model": model, "prompt": prompt}, sort_keys=True).encode()).hexdigest()
        if cached := self._cached(key):
            return self._response(name, task, cached.result, cached.model, True, cached.redactions, cached.digest, {})
        if not self.gate.acquire(timeout=min(self.settings.timeout, 10)):
            raise Unavailable("local_ai_busy", "The local AI worker is busy")
        try:
            try:
                raw, metrics = self.client.chat(
                    model=model,
                    system_prompt=task.prompt + f"\nRules: local=true; role={role}; advisory_only=true; hosted_fallback=false; stable_diffusion=false; never_send_or_apply=true. Return exactly one JSON object.",
                    user_prompt=prompt,
                    generation=self.models.generation,
                )
            except (OllamaError, PolicyError, OSError, ValueError) as exc:
                raise Unavailable("local_ai_request_failed", "The local model could not complete the request") from exc
        finally:
            self.gate.release()
        if not isinstance(raw, Mapping):
            raise Unavailable("invalid_model_response", "The local model returned an invalid response")
        result = _result(task, raw)
        digest = hashlib.sha256(redacted.text.encode()).hexdigest()
        actual_model = str(metrics.get("model") or model)
        self._remember(key, CacheEntry(self.clock(), dict(result), actual_model, redacted.replacements, digest))
        return self._response(name, task, result, actual_model, False, redacted.replacements, digest, metrics)

    @staticmethod
    def _response(name: str, task: Task, result: Mapping[str, Any], model: str, cached: bool, redactions: int, digest: str, metrics: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "requestID": str(uuid.uuid4()), "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "task": name, "provider": "ollama", "model": model, "local": True, "cached": cached,
            "advisoryOnly": True, "hostedFallbackUsed": False, "hostedCreditsUsed": 0,
            "stableDiffusionUsed": False, "needsHumanApproval": True, "redactions": redactions,
            "inputDigest": digest,
            "metrics": {key: metrics.get(key) for key in ("elapsed_seconds", "prompt_eval_count", "eval_count") if metrics.get(key) is not None},
            "result": dict(result),
        }


def load_routing(path: Path = ROUTING_POLICY_PATH) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        raise InvalidRequest("invalid_routing_policy", f"Cannot load local AI routing policy: {path}") from exc
    if not isinstance(value, dict) or value.get("text_and_reasoning", {}).get("hosted_fallback_enabled", True):
        raise InvalidRequest("unsafe_routing_policy", "Hosted AI fallback must remain disabled")
    if value.get("image_generation", {}).get("provider") != "stable-diffusion":
        raise InvalidRequest("invalid_routing_policy", "Stable Diffusion must remain isolated as the image provider")
    return value


def create_gateway(env: Mapping[str, str] | None = None, client: Any | None = None) -> LocalAIGateway:
    return LocalAIGateway(
        Settings.from_env(env), load_config(MODELS_PATH), load_policy(LOCAL_POLICY_PATH), load_routing(), client
    )
