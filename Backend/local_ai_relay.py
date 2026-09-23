"""Ephemeral, single-process broker for an authenticated outbound Mac worker.

No listener, model client, persistent queue, request cache or hosted-model fallback
is created here. A claimed job is never requeued, including after worker failure.
Local execution metadata describes the configured worker contract, not independent
proof about the machine or its network. Deployment must use one backend process.
"""
from __future__ import annotations

import copy
import dataclasses
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import threading
import time
import uuid
from datetime import datetime
from typing import Any, Callable, Mapping

from Backend.local_ai_gateway import (
    Forbidden, GatewayError, InvalidRequest, LocalAIGateway, Settings, TASKS,
    Unavailable, _result, redact_text, validated_request_prompt,
)

MODEL = "gunnaire-coder:ops"
_FAILURES = frozenset({"unavailable", "busy", "request_failed", "invalid_model_response"})


@dataclasses.dataclass(frozen=True)
class RelaySettings:
    company_id: str
    worker_id: str
    worker_secret: str | bytes = dataclasses.field(repr=False)
    model_digest: str
    model: str = MODEL
    job_ttl: float = 90.0
    heartbeat_ttl: float = 15.0
    max_jobs: int = 4

    def __post_init__(self) -> None:
        try:
            valid_company = isinstance(self.company_id, str) and str(uuid.UUID(self.company_id)) == self.company_id.lower()
        except (ValueError, AttributeError):
            valid_company = False
        try:
            token = self.worker_secret.encode("ascii") if isinstance(self.worker_secret, str) else self.worker_secret
        except UnicodeEncodeError:
            raise InvalidRequest("invalid_relay_configuration", "Worker credentials must use the permitted ASCII alphabet") from None
        if not valid_company or not isinstance(self.worker_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", self.worker_id):
            raise InvalidRequest("invalid_relay_configuration", "Relay requires an explicit company UUID and worker identity")
        if not isinstance(token, bytes) or not re.fullmatch(rb"[A-Za-z0-9._~+/=-]{32,512}", token):
            raise InvalidRequest("invalid_relay_configuration", "Relay requires a separate printable worker credential of at least 32 bytes")
        if self.model != MODEL or not isinstance(self.model_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", self.model_digest):
            raise InvalidRequest("invalid_relay_configuration", "Relay requires the approved model and an explicit SHA256 digest")
        for value, maximum in ((self.job_ttl, 90), (self.heartbeat_ttl, 15)):
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 < value <= maximum or not math.isfinite(value):
                raise InvalidRequest("invalid_relay_configuration", "Relay deadlines exceed the permitted bounds")
        if type(self.max_jobs) is not int or not 1 <= self.max_jobs <= 4:
            raise InvalidRequest("invalid_relay_configuration", "Relay capacity must be between one and four")
        object.__setattr__(self, "company_id", self.company_id.lower())
        object.__setattr__(self, "worker_secret", token)

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "RelaySettings":
        source = os.environ if env is None else env
        digest = source.get("GUNNAIRE_LOCAL_AI_MODEL_DIGEST", "").removeprefix("sha256:").lower()
        return cls(
            company_id=source.get("GUNNAIRE_LOCAL_AI_COMPANY_ID", ""),
            worker_id=source.get("GUNNAIRE_LOCAL_AI_WORKER_ID", ""),
            worker_secret=source.get("GUNNAIRE_LOCAL_AI_WORKER_TOKEN", ""),
            model_digest=digest,
        )


@dataclasses.dataclass(repr=False)
class _Job:
    job_id: str
    scope_id: str
    task: str
    actor_role: str
    request: dict[str, Any]
    authorize: Callable[[], bool] | None
    expires: float
    input_digest: str
    redactions: int
    state: str = "admitting"
    claim_id: str | None = None
    response: dict[str, Any] | None = None
    error: GatewayError | None = None


class LocalAIRelay:
    def __init__(self, settings: RelaySettings, gateway_settings: Settings | None = None,
                 *, clock: Callable[[], float] = time.monotonic) -> None:
        self.settings = settings
        self.gateway_settings = gateway_settings or Settings()
        self.clock = clock
        self._condition = threading.Condition()
        self._jobs: dict[str, _Job] = {}
        self._heartbeat_at: float | None = None
        self._ready = False
        self._busy = False
        self._closed = False
        self._expiry_thread = threading.Thread(target=self._expire_loop, name="local-ai-relay-expiry", daemon=True)
        self._expiry_thread.start()

    def authenticate_worker(self, authorization_header: str) -> bool:
        if not isinstance(authorization_header, str) or not authorization_header.startswith("Bearer "):
            return False
        candidate = authorization_header[7:]
        if len(candidate) > 512:
            return False
        try:
            return hmac.compare_digest(candidate.encode("ascii"), self.settings.worker_secret)
        except UnicodeEncodeError:
            return False

    def _identity(self, body: Mapping[str, Any], keys: set[str]) -> None:
        if not isinstance(body, Mapping) or set(body) != keys:
            raise InvalidRequest("invalid_worker_request", "Worker request fields do not match the protocol")
        if body.get("companyID") != self.settings.company_id or body.get("workerID") != self.settings.worker_id:
            raise Forbidden("worker_identity_mismatch", "Worker identity does not match the configured company")

    @staticmethod
    def _authorized(callback: Callable[[], bool] | None) -> bool:
        # Callers must release the broker lock before entering application code.
        try:
            return callback is not None and callback() is True
        except Exception:
            return False

    def _end(self, job: _Job, error: GatewayError | None = None) -> None:
        if self._jobs.get(job.job_id) is job:
            self._jobs.pop(job.job_id)
        job.request.clear()
        job.response = None
        job.authorize = None
        job.scope_id = ""
        job.input_digest = ""
        job.error = error
        job.state = "terminal"
        self._condition.notify_all()

    def _sweep(self) -> None:
        now = self.clock()
        for job in list(self._jobs.values()):
            if now >= job.expires:
                self._end(job, Unavailable("local_ai_expired", "The local AI request expired; it will not be retried"))

    def _expire_loop(self) -> None:
        with self._condition:
            while not self._closed:
                self._sweep()
                delay = min((max(0.001, job.expires - self.clock()) for job in self._jobs.values()), default=1.0)
                self._condition.wait(timeout=min(delay, 1.0))

    def close(self) -> None:
        with self._condition:
            self._closed = True
            for job in list(self._jobs.values()):
                self._end(job, Unavailable("local_ai_unavailable", "The local AI relay stopped"))
            self._condition.notify_all()
        if threading.current_thread() is not self._expiry_thread:
            self._expiry_thread.join(timeout=2)

    def _live(self) -> bool:
        return not self._closed and self.gateway_settings.enabled and self._heartbeat_at is not None and 0 <= self.clock() - self._heartbeat_at < self.settings.heartbeat_ttl and self._ready

    def _claimed(self) -> bool:
        return any(job.state in {"claim_authorizing", "claimed", "completing"} for job in self._jobs.values())

    def status(self) -> dict[str, Any]:
        with self._condition:
            self._sweep()
            live = self._live()
            busy = live and (self._busy or self._claimed() or len(self._jobs) >= self.settings.max_jobs)
            available = live and not busy
            tasks = sorted(TASKS)
            return {
                "enabled": self.gateway_settings.enabled and not self._closed,
                "provider": "ollama", "local": True, "endpointScope": "outbound-worker",
                "hostedFallbackEnabled": False, "hostedCreditsUsed": 0,
                "stableDiffusionScope": "image-only", "supportedTasks": tasks,
                "available": available, "status": "busy" if busy else "ready" if live else "unavailable",
                "models": {"worker": self.settings.model},
                "installedModels": [self.settings.model] if live else [],
                "missingModels": [] if live else [self.settings.model],
                "availableTasks": tasks if available else [], "unavailableTasks": [] if available else tasks,
                "taskModels": {name: {"role": task.preferred_role, "model": self.settings.model} for name, task in TASKS.items()} if available else {},
                "transport": "outbound-worker", "executionEvidence": "authenticated-worker-heartbeat",
            }

    def heartbeat(self, body: Mapping[str, Any]) -> dict[str, Any]:
        self._identity(body, {"companyID", "workerID", "ready", "busy", "model", "modelDigest", "provider", "local", "hostedFallbackEnabled"})
        if (type(body["ready"]) is not bool or type(body["busy"]) is not bool
                or body["model"] != self.settings.model or body["modelDigest"] != self.settings.model_digest
                or body["provider"] != "ollama" or body["local"] is not True or body["hostedFallbackEnabled"] is not False):
            raise InvalidRequest("invalid_worker_readiness", "Worker readiness does not match the pinned local execution contract")
        with self._condition:
            self._sweep()
            if self._closed or not self.gateway_settings.enabled:
                raise Unavailable("local_ai_disabled", "The local AI relay is disabled")
            self._heartbeat_at, self._ready, self._busy = self.clock(), body["ready"], body["busy"]
            self._condition.notify_all()
            return {"accepted": True, "heartbeatTTLSeconds": self.settings.heartbeat_ttl}

    def _require_state(self, job: _Job, state: str) -> None:
        self._sweep()
        if job.error is not None:
            raise job.error
        if self._closed or self._jobs.get(job.job_id) is not job or job.state != state:
            raise Unavailable("local_ai_expired", "The local AI operation is no longer current")

    def assist(self, payload: Mapping[str, Any], actor_role: str, authorize: Callable[[], bool], *, scope_id: str,
               deadline: float | None = None) -> dict[str, Any]:
        admitted = self.clock()
        expires = admitted + self.settings.job_ttl
        if deadline is not None:
            if type(deadline) not in (int, float) or not -1e15 < deadline < 1e15 or not math.isfinite(deadline):
                raise InvalidRequest("invalid_deadline", "Local AI requires a finite monotonic deadline")
            expires = min(expires, deadline)
        if not isinstance(scope_id, str) or not 1 <= len(scope_id) <= 256 or not callable(authorize):
            raise Forbidden("invalid_request_authorization", "Local AI requires a bound application session")
        request, _, prompt = validated_request_prompt(payload, actor_role, self.gateway_settings)
        if len(json.dumps(request, ensure_ascii=False, allow_nan=False).encode("utf-8")) > 49_152:
            raise InvalidRequest("request_too_large", "AI request exceeds the transport byte limit")
        redacted = redact_text(prompt)
        digest = hashlib.sha256(redacted.text.encode()).hexdigest()
        job = _Job(secrets.token_urlsafe(32), scope_id, request["task"], actor_role, request, authorize,
                   expires, digest, redacted.replacements)
        del prompt, redacted, request, payload, authorize
        try:
            with self._condition:
                self._sweep()
                if self.clock() >= expires:
                    raise Unavailable("local_ai_expired", "The local AI request expired before admission")
                if not self._live():
                    raise Unavailable("local_ai_unavailable", "No ready authenticated local worker is available")
                if len(self._jobs) >= self.settings.max_jobs or any(item.scope_id == scope_id for item in self._jobs.values()):
                    raise Unavailable("local_ai_busy", "The local AI request limit is reached")
                # An unclaimable reservation bounds admission checks and allows expiry
                # to erase its contents while the database authorization is pending.
                self._jobs[job.job_id] = job
                callback = job.authorize
                self._condition.notify_all()
            allowed = self._authorized(callback)
            del callback
            with self._condition:
                self._require_state(job, "admitting")
                if not allowed:
                    raise Forbidden("authorization_changed", "The original business session is no longer authorized")
                job.state = "queued"
                self._condition.notify_all()
                while job.state not in {"completed", "terminal"}:
                    self._sweep()
                    if job.state != "terminal":
                        self._condition.wait(timeout=min(1.0, max(0.001, job.expires - self.clock())))
                self._require_state(job, "completed")
                job.state = "return_authorizing"
                callback = job.authorize
            allowed = self._authorized(callback)
            del callback
            with self._condition:
                self._require_state(job, "return_authorizing")
                if not allowed:
                    raise Forbidden("authorization_changed", "The original business session is no longer authorized")
                if job.response is None:
                    raise Unavailable("invalid_model_response", "The local worker did not return a response")
                return copy.deepcopy(job.response)
        finally:
            with self._condition:
                self._end(job)

    def claim(self, body: Mapping[str, Any]) -> dict[str, Any]:
        self._identity(body, {"companyID", "workerID"})
        while True:
            with self._condition:
                self._sweep()
                if not self._live():
                    raise Unavailable("local_ai_unavailable", "The local worker heartbeat is unavailable")
                if self._busy or self._claimed():
                    return {"job": None}
                job = next((item for item in self._jobs.values() if item.state == "queued"), None)
                if job is None:
                    return {"job": None}
                job.state = "claim_authorizing"
                callback = job.authorize
            allowed = self._authorized(callback)
            del callback
            with self._condition:
                self._sweep()
                if self._jobs.get(job.job_id) is not job or job.state != "claim_authorizing":
                    return {"job": None}
                if not allowed:
                    self._end(job, Forbidden("authorization_changed", "The original business session is no longer authorized"))
                    continue
                if not self._live() or self._busy:
                    self._end(job, Unavailable("local_ai_unavailable", "The local worker is no longer ready"))
                    return {"job": None}
                job.claim_id = secrets.token_urlsafe(32)
                job.state = "claimed"
                return {"job": {
                    "companyID": self.settings.company_id, "workerID": self.settings.worker_id,
                    "jobID": job.job_id, "claimID": job.claim_id, "task": job.task, "actorRole": job.actor_role,
                    "model": self.settings.model, "modelDigest": self.settings.model_digest,
                    "expiresInSeconds": job.expires - self.clock(), "request": copy.deepcopy(job.request),
                }}

    def _response(self, job: _Job, response: Any) -> dict[str, Any]:
        required = {"requestID", "generatedAt", "task", "provider", "model", "local", "cached", "advisoryOnly", "hostedFallbackUsed", "hostedCreditsUsed", "stableDiffusionUsed", "needsHumanApproval", "redactions", "inputDigest", "metrics", "result"}
        invalid = Unavailable("invalid_model_response", "The local worker returned an invalid response")
        if not isinstance(response, Mapping) or set(response) != required:
            raise invalid
        try:
            if len(json.dumps(response, ensure_ascii=False, allow_nan=False).encode("utf-8")) > 60_000:
                raise invalid
            uuid.UUID(response["requestID"])
            generated = datetime.fromisoformat(response["generatedAt"].replace("Z", "+00:00"))
            if generated.tzinfo is None:
                raise invalid
        except (ValueError, TypeError, AttributeError, OverflowError, RecursionError):
            raise invalid from None
        if (response["task"] != job.task or response["provider"] != "ollama" or response["model"] != self.settings.model
                or response["local"] is not True or response["cached"] is not False or response["advisoryOnly"] is not True
                or response["hostedFallbackUsed"] is not False or type(response["hostedCreditsUsed"]) is not int or response["hostedCreditsUsed"] != 0
                or response["stableDiffusionUsed"] is not False or response["needsHumanApproval"] is not True
                or type(response["redactions"]) is not int or response["redactions"] != job.redactions
                or response["inputDigest"] != job.input_digest):
            raise invalid
        task = TASKS[job.task]
        result = response["result"]
        if not isinstance(result, Mapping) or set(result) != task.strings | task.lists | task.numbers:
            raise invalid
        if any(not isinstance(result[key], str) for key in task.strings):
            raise invalid
        if any(not isinstance(result[key], list) or len(result[key]) > 20 or any(not isinstance(item, str) for item in result[key]) for key in task.lists):
            raise invalid
        if any(type(result[key]) not in (int, float) or not 0 <= result[key] <= 1 or not math.isfinite(result[key]) for key in task.numbers):
            raise invalid
        if _result(task, result) != result:
            raise invalid
        metrics = response["metrics"]
        if not isinstance(metrics, Mapping) or not set(metrics) <= {"elapsed_seconds", "prompt_eval_count", "eval_count"}:
            raise invalid
        for key, value in metrics.items():
            if type(value) not in (int, float) or not 0 <= value <= 1_000_000_000 or not math.isfinite(value):
                raise invalid
            if key != "elapsed_seconds" and type(value) is not int:
                raise invalid
        return LocalAIGateway._response(job.task, task, result, self.settings.model, False, job.redactions, job.input_digest, metrics)

    def complete(self, body: Mapping[str, Any]) -> dict[str, Any]:
        base = {"companyID", "workerID", "jobID", "claimID", "task"}
        self._identity(body, base | ({"response"} if isinstance(body, Mapping) and "response" in body else {"failureCode"}))
        if any(not isinstance(body[key], str) for key in ("jobID", "claimID", "task")):
            raise InvalidRequest("invalid_worker_request", "Worker completion identity must be text")
        failure = None
        with self._condition:
            self._sweep()
            job = self._jobs.get(body["jobID"])
            if job is None or job.state != "claimed" or job.claim_id != body["claimID"] or job.task != body["task"]:
                raise InvalidRequest("stale_worker_claim", "The worker claim is unknown, expired or already completed")
            try:
                if "failureCode" in body:
                    if not isinstance(body["failureCode"], str) or body["failureCode"] not in _FAILURES:
                        raise InvalidRequest("invalid_worker_request", "Worker failure code is not recognized")
                    failure = Unavailable("local_ai_" + body["failureCode"], "The local worker could not complete this request; it will not be retried")
                else:
                    # Pending result stays in the expirable job, never in a local
                    # reference spanning a potentially slow authorization callback.
                    job.response = self._response(job, body["response"])
            except GatewayError as error:
                self._end(job, error)
                raise
            job.request.clear()
            job.state = "completing"
            callback = job.authorize
        del body
        allowed = self._authorized(callback)
        del callback
        with self._condition:
            self._require_state(job, "completing")
            if not allowed:
                error = Forbidden("authorization_changed", "The original business session is no longer authorized")
                self._end(job, error)
                raise error
            if failure is not None:
                self._end(job, failure)
            else:
                job.state = "completed"
                self._condition.notify_all()
            return {"accepted": True}


def create_relay(env: Mapping[str, str] | None = None) -> LocalAIRelay:
    return LocalAIRelay(RelaySettings.from_env(env), Settings.from_env(env))
