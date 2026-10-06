from __future__ import annotations

import dataclasses
import hashlib
import threading
import unittest
from unittest.mock import patch

from Backend import local_ai_gateway as gateway
from Backend.local_ai_relay import LocalAIRelay, RelaySettings, create_relay

COMPANY = "515c1e20-2951-437a-afd4-9867c82d1f41"
DIGEST = "a" * 64
TOKEN = "synthetic-worker-secret-" + "x" * 32
REQUEST = {"task": "customer_email_draft", "input": "Draft a service follow-up.", "context": {"job": "synthetic"}}


class Clock:
    def __init__(self):
        self.now = 100.0
        self.lock = threading.Lock()

    def __call__(self):
        with self.lock:
            return self.now

    def advance(self, seconds):
        with self.lock:
            self.now += seconds


class RelayTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.subject = LocalAIRelay(RelaySettings(COMPANY, "synthetic-mac", TOKEN, DIGEST), clock=self.clock)
        self.addCleanup(self.subject.close)
        self.threads = []
        self.addCleanup(self.join_threads)
        self.subject.heartbeat(self.heartbeat())

    def join_threads(self):
        self.subject.close()
        for thread in self.threads:
            thread.join(2)
            self.assertFalse(thread.is_alive())

    def identity(self):
        return {"companyID": COMPANY, "workerID": "synthetic-mac"}

    def heartbeat(self, **changes):
        return {**self.identity(), "ready": True, "busy": False, "model": "gunnaire-coder:ops", "modelDigest": DIGEST,
                "provider": "ollama", "local": True, "hostedFallbackEnabled": False, **changes}

    def start(self, *, payload=None, role="Admin", authorize=lambda: True, scope="session-one", deadline=None):
        outcome = {}
        def run():
            try:
                outcome["result"] = self.subject.assist(payload or REQUEST, role, authorize, scope_id=scope, deadline=deadline)
            except gateway.GatewayError as error:
                outcome["error"] = error
        thread = threading.Thread(target=run)
        self.threads.append(thread)
        thread.start()
        return thread, outcome

    def queued(self, count=1):
        with self.subject._condition:
            self.assertTrue(self.subject._condition.wait_for(lambda: len(self.subject._jobs) == count and all(item.state == "queued" for item in self.subject._jobs.values()), timeout=2))
            return list(self.subject._jobs.values())

    def claim(self):
        job = self.subject.claim(self.identity())["job"]
        self.assertIsNotNone(job)
        return job

    def response(self, job, result=None):
        request, task, prompt = gateway.validated_request_prompt(job["request"], job["actorRole"], self.subject.gateway_settings)
        redacted = gateway.redact_text(prompt)
        return gateway.LocalAIGateway._response(job["task"], task,
            result or {"subject": "Service follow-up", "body": "Please review the service notes.", "warnings": []},
            job["model"], False, redacted.replacements, hashlib.sha256(redacted.text.encode()).hexdigest(),
            {"elapsed_seconds": 0.1, "prompt_eval_count": 5, "eval_count": 4})

    def completion(self, job, **changes):
        return {**{key: job[key] for key in ("companyID", "workerID", "jobID", "claimID", "task")}, "response": self.response(job), **changes}

    def finish(self, thread, outcome):
        thread.join(2)
        self.assertFalse(thread.is_alive())
        return outcome

    def test_roundtrip_rebuilds_envelope_and_clears_every_payload_reference(self):
        thread, outcome = self.start()
        retained = self.queued()[0]
        job = self.claim()
        completion = self.completion(job)
        worker_id = completion["response"]["requestID"]
        self.assertEqual(self.subject.complete(completion), {"accepted": True})
        result = self.finish(thread, outcome)["result"]
        self.assertNotEqual(result["requestID"], worker_id)
        self.assertEqual(result["result"], completion["response"]["result"])
        self.assertFalse(result["cached"])
        self.assertEqual(self.subject._jobs, {})
        self.assertEqual(retained.request, {})
        self.assertIsNone(retained.response)
        self.assertIsNone(retained.authorize)
        self.assertEqual(retained.scope_id, "")
        self.assertEqual(retained.input_digest, "")

    def test_status_requires_fresh_ready_heartbeat_and_reports_busy(self):
        self.assertTrue(self.subject.status()["available"])
        self.assertEqual(self.subject.status()["endpointScope"], "outbound-worker")
        self.subject.heartbeat(self.heartbeat(busy=True))
        self.assertEqual(self.subject.status()["status"], "busy")
        self.assertIsNone(self.subject.claim(self.identity())["job"])
        self.clock.advance(15)
        self.assertFalse(self.subject.status()["available"])
        self.subject.heartbeat(self.heartbeat(ready=False))
        self.assertFalse(self.subject.status()["available"])

    def test_fresh_relay_and_restart_have_no_readiness_or_jobs(self):
        another = LocalAIRelay(self.subject.settings, clock=self.clock)
        self.addCleanup(another.close)
        self.assertFalse(another.status()["available"])
        thread, outcome = self.start()
        self.queued()
        old_job = self.claim()
        self.subject.close()
        self.assertIn("error", self.finish(thread, outcome))
        with self.assertRaises(gateway.InvalidRequest):
            another.complete(self.completion(old_job))
        self.assertEqual(another._jobs, {})

    def test_claim_and_job_tokens_are_distinct_opaque_and_never_reused(self):
        ids = set()
        for _ in range(2):
            thread, outcome = self.start()
            self.queued()
            job = self.claim()
            self.assertNotIn(job["jobID"], ids)
            self.assertNotIn(job["claimID"], ids)
            self.assertNotEqual(job["claimID"], job["jobID"])
            ids.update((job["jobID"], job["claimID"]))
            self.subject.complete(self.completion(job))
            self.finish(thread, outcome)

    def test_concurrent_claims_allow_only_one_outstanding_execution(self):
        first, one = self.start(scope="first")
        self.queued()
        second, two = self.start(scope="second")
        self.queued(2)
        barrier = threading.Barrier(3)
        claims = []
        def claim():
            barrier.wait()
            claims.append(self.subject.claim(self.identity())["job"])
        competitors = [threading.Thread(target=claim) for _ in range(2)]
        for thread in competitors:
            thread.start()
        barrier.wait()
        for thread in competitors:
            thread.join(2)
        jobs = [job for job in claims if job is not None]
        self.assertEqual(len(jobs), 1)
        self.subject.complete(self.completion(jobs[0]))
        self.finish(first, one)
        second_job = self.claim()
        self.subject.complete(self.completion(second_job))
        self.assertIn("result", self.finish(second, two))

    def test_global_capacity_four_and_single_session_capacity_one(self):
        handles = []
        for index in range(4):
            handles.append(self.start(scope=str(index)))
            self.queued(index + 1)
        for scope in ("0", "new-session"):
            with self.assertRaises(gateway.Unavailable) as raised:
                self.subject.assist(REQUEST, "Admin", lambda: True, scope_id=scope)
            self.assertEqual(raised.exception.code, "local_ai_busy")
        self.assertEqual(len(self.subject._jobs), 4)
        self.assertFalse(self.subject.status()["available"])
        self.subject.close()
        for thread, outcome in handles:
            self.assertIn("error", self.finish(thread, outcome))

    def test_same_session_cannot_enqueue_second_job_below_global_capacity(self):
        thread, outcome = self.start()
        self.queued()
        with self.assertRaises(gateway.Unavailable):
            self.subject.assist(REQUEST, "Admin", lambda: True, scope_id="session-one")
        self.assertEqual(len(self.subject._jobs), 1)

    def test_shared_request_validation_runs_before_enqueue(self):
        cases = [({"task": "missing", "input": "text"}, "Admin"),
                 ({"task": "security_review", "input": "text"}, "Standard"),
                 ({**REQUEST, "context": {"access_token": "secret"}}, "Admin"),
                 ({**REQUEST, "context": {"number": float("nan")}}, "Admin"),
                 ({**REQUEST, "input": "x" * 20001}, "Admin"),
                 ({**REQUEST, "context": []}, "Admin")]
        for payload, role in cases:
            with self.subTest(payload=payload["task"], role=role):
                with self.assertRaises(gateway.GatewayError):
                    self.subject.assist(payload, role, lambda: True, scope_id="session")
                self.assertEqual(self.subject._jobs, {})

    def test_authorization_must_be_explicit_true_before_enqueue(self):
        for value in (False, None, 1, "authorized"):
            with self.subTest(value=value):
                with self.assertRaises(gateway.Forbidden):
                    self.subject.assist(REQUEST, "Admin", lambda: value, scope_id="session")
                self.assertEqual(self.subject._jobs, {})
        def broken():
            raise RuntimeError("synthetic")
        with self.assertRaises(gateway.Forbidden):
            self.subject.assist(REQUEST, "Admin", broken, scope_id="session")

    def test_revocation_before_claim_cleans_job_without_leaking_request(self):
        permit = [True]
        thread, outcome = self.start(authorize=lambda: permit[0])
        retained = self.queued()[0]
        permit[0] = False
        self.assertIsNone(self.subject.claim(self.identity())["job"])
        self.assertIsInstance(self.finish(thread, outcome)["error"], gateway.Forbidden)
        self.assertEqual(retained.request, {})
        self.assertIsNone(retained.authorize)

    def test_revocation_before_completion_rejects_and_cleans(self):
        permit = [True]
        thread, outcome = self.start(authorize=lambda: permit[0])
        retained = self.queued()[0]
        job = self.claim()
        permit[0] = False
        with self.assertRaises(gateway.Forbidden):
            self.subject.complete(self.completion(job))
        self.assertIsInstance(self.finish(thread, outcome)["error"], gateway.Forbidden)
        self.assertEqual(retained.request, {})

    def test_authorization_rechecked_before_result_leaves_assist(self):
        permit = [True]
        thread, outcome = self.start(authorize=lambda: permit[0])
        self.queued()
        job = self.claim()
        with self.subject._condition:
            self.subject.complete(self.completion(job))
            permit[0] = False
        self.assertIsInstance(self.finish(thread, outcome)["error"], gateway.Forbidden)
        self.assertEqual(self.subject._jobs, {})

    def test_expiry_budget_covers_queue_time_and_claim_is_not_requeued(self):
        thread, outcome = self.start()
        retained = self.queued()[0]
        self.clock.advance(20)
        self.subject.heartbeat(self.heartbeat())
        job = self.claim()
        self.assertEqual(job["expiresInSeconds"], 70)
        self.clock.advance(70)
        self.subject.heartbeat(self.heartbeat())
        self.assertEqual(self.finish(thread, outcome)["error"].code, "local_ai_expired")
        self.assertEqual(retained.request, {})
        self.assertIsNone(self.subject.claim(self.identity())["job"])
        with self.assertRaises(gateway.InvalidRequest):
            self.subject.complete(self.completion(job))

    def test_expiry_thread_cleans_payload_without_any_public_operation(self):
        thread, outcome = self.start()
        retained = self.queued()[0]
        self.clock.advance(90)
        # Wake only the timer condition; invoke no status/heartbeat/claim/complete.
        with self.subject._condition:
            self.subject._condition.notify_all()
        self.assertEqual(self.finish(thread, outcome)["error"].code, "local_ai_expired")
        self.assertEqual(retained.request, {})
        self.assertIsNone(retained.authorize)

    def test_claimed_job_remains_single_after_heartbeat_and_lost_claim_response(self):
        thread, outcome = self.start()
        self.queued()
        self.claim()
        self.subject.heartbeat(self.heartbeat())
        for _ in range(3):
            self.assertIsNone(self.subject.claim(self.identity())["job"])
        self.assertEqual(len(self.subject._jobs), 1)

    def test_failure_is_terminal_without_retry_or_requeue(self):
        thread, outcome = self.start()
        retained = self.queued()[0]
        job = self.claim()
        failed = {key: job[key] for key in ("companyID", "workerID", "jobID", "claimID", "task")}
        failed["failureCode"] = "request_failed"
        self.assertEqual(self.subject.complete(failed), {"accepted": True})
        self.assertIn("error", self.finish(thread, outcome))
        self.assertEqual(retained.request, {})
        self.assertIsNone(self.subject.claim(self.identity())["job"])
        with self.assertRaises(gateway.InvalidRequest):
            self.subject.complete(failed)

    def test_wrong_identity_claim_task_and_duplicate_completion_never_replace_result(self):
        thread, outcome = self.start()
        self.queued()
        job = self.claim()
        completion = self.completion(job)
        for key in ("companyID", "workerID", "jobID", "claimID", "task"):
            with self.subTest(key=key):
                with self.assertRaises(gateway.GatewayError):
                    self.subject.complete({**completion, key: "wrong"})
                self.assertEqual(len(self.subject._jobs), 1)
        with self.subject._condition:
            self.subject.complete(completion)
            with self.assertRaises(gateway.InvalidRequest):
                self.subject.complete(completion)
        self.assertEqual(self.finish(thread, outcome)["result"]["result"], completion["response"]["result"])
        with self.assertRaises(gateway.InvalidRequest):
            self.subject.complete(completion)

    def test_unclaimed_completion_and_other_worker_heartbeat_cannot_advance_job(self):
        thread, outcome = self.start()
        retained = self.queued()[0]
        with self.assertRaises(gateway.InvalidRequest):
            self.subject.complete({**self.identity(), "jobID": retained.job_id, "claimID": "not-claimed", "task": retained.task, "failureCode": "busy"})
        with self.assertRaises(gateway.Forbidden):
            self.subject.heartbeat(self.heartbeat(workerID="another"))
        self.assertIsNone(retained.claim_id)

    def test_malformed_and_nonlocal_metadata_are_terminal_and_never_returned(self):
        mutations = [lambda r: r.update(provider="remote"), lambda r: r.update(local=False),
                     lambda r: r.update(model="arbitrary"), lambda r: r.update(cached=True),
                     lambda r: r.update(hostedFallbackUsed=True), lambda r: r.update(hostedCreditsUsed=True),
                     lambda r: r.update(inputDigest="b" * 64), lambda r: r.update(redactions=999),
                     lambda r: r.update(metrics={"elapsed_seconds": float("nan")}),
                     lambda r: r.update(metrics={"eval_count": 1.5}),
                     lambda r: r.update(result={"subject": "test", "body": "test", "warnings": [], "commands": []}),
                     lambda r: r.update(result={"subject": "", "body": "test", "warnings": []}),
                     lambda r: r.update(result={"subject": "test", "body": "test", "warnings": [1]}),
                     lambda r: r.update(generatedAt="invalid"), lambda r: r.update(requestID="not-uuid")]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                thread, outcome = self.start()
                retained = self.queued()[0]
                job = self.claim()
                completion = self.completion(job)
                mutate(completion["response"])
                with self.assertRaises(gateway.Unavailable):
                    self.subject.complete(completion)
                self.assertIsInstance(self.finish(thread, outcome)["error"], gateway.Unavailable)
                self.assertEqual(retained.request, {})
                self.assertEqual(self.subject._jobs, {})

    def test_nonfinite_result_rejected_by_both_gateway_and_relay(self):
        task = gateway.TASKS["document_classification"]
        for number in (float("nan"), float("inf"), -float("inf")):
            with self.assertRaises(gateway.Unavailable):
                gateway._result(task, {"document_type": "unknown", "reason": "Insufficient evidence", "confidence": number})
        payload = {"task": "document_classification", "input": "A synthetic document"}
        thread, outcome = self.start(payload=payload)
        self.queued()
        job = self.claim()
        response = self.response(job, {"document_type": "unknown", "reason": "Insufficient evidence", "confidence": float("nan"), "warnings": []})
        with self.assertRaises(gateway.Unavailable):
            self.subject.complete(self.completion(job, response=response))
        self.assertIn("error", self.finish(thread, outcome))

    def test_revocation_during_response_validation_is_rechecked_before_acceptance(self):
        permit = [True]
        thread, outcome = self.start(authorize=lambda: permit[0])
        self.queued()
        job = self.claim()
        validate = self.subject._response
        def validate_then_revoke(*args):
            value = validate(*args)
            permit[0] = False
            return value
        with patch.object(self.subject, "_response", validate_then_revoke):
            with self.assertRaises(gateway.Forbidden):
                self.subject.complete(self.completion(job))
        self.assertIsInstance(self.finish(thread, outcome)["error"], gateway.Forbidden)

    def test_expired_admission_never_claims_or_blocks_later_request(self):
        def authorization():
            self.clock.advance(90)
            return True
        thread, outcome = self.start(authorize=authorization)
        self.finish(thread, outcome)
        self.assertIn(outcome["error"].code, {"local_ai_unavailable", "local_ai_expired"})
        self.assertEqual(self.subject._jobs, {})
        self.subject.heartbeat(self.heartbeat())
        next_thread, next_outcome = self.start()
        self.queued()
        job = self.claim()
        self.assertEqual(job["expiresInSeconds"], 90)
        self.subject.complete(self.completion(job))
        self.assertIn("result", self.finish(next_thread, next_outcome))

    def test_expired_claim_releases_capacity_without_requeueing_old_request(self):
        first_thread, first = self.start()
        self.queued()
        old = self.claim()
        self.clock.advance(90)
        self.subject.heartbeat(self.heartbeat())
        self.assertIn("error", self.finish(first_thread, first))
        next_thread, next_outcome = self.start()
        self.queued()
        current = self.claim()
        with self.assertRaises(gateway.InvalidRequest):
            self.subject.complete(self.completion(old))
        self.assertEqual(len(self.subject._jobs), 1)
        self.assertNotEqual(old["claimID"], current["claimID"])
        self.subject.complete(self.completion(current))
        self.assertIn("result", self.finish(next_thread, next_outcome))

    def test_paused_authorization_at_each_stage_cannot_block_expiry_or_status(self):
        for stage, pause_on in (("admission", 1), ("claim", 2), ("completion", 3), ("return", 4)):
            with self.subTest(stage=stage):
                entered, release = threading.Event(), threading.Event()
                self.addCleanup(release.set)
                calls = [0]
                def authorization():
                    calls[0] += 1
                    if calls[0] == pause_on:
                        entered.set()
                        release.wait(5)
                    return True
                actor_result = {}
                def worker_call(call):
                    try:
                        actor_result["result"] = call()
                    except gateway.GatewayError as error:
                        actor_result["error"] = error
                thread, outcome = self.start(authorize=authorization)
                actor = None
                if stage != "admission":
                    self.queued()
                    if stage == "claim":
                        actor = threading.Thread(target=worker_call, args=(lambda: self.subject.claim(self.identity()),))
                    else:
                        job = self.claim()
                        if stage == "completion":
                            actor = threading.Thread(target=worker_call, args=(lambda: self.subject.complete(self.completion(job)),))
                        else:
                            self.subject.complete(self.completion(job))
                    if actor:
                        self.threads.append(actor)
                        actor.start()
                self.assertTrue(entered.wait(2))
                retained = list(self.subject._jobs.values())[0]
                self.clock.advance(90)
                observer_done = threading.Event()
                def observe():
                    self.subject.status()
                    observer_done.set()
                observer = threading.Thread(target=observe)
                self.threads.append(observer)
                observer.start()
                try:
                    self.assertTrue(observer_done.wait(1), "paused database callback held broker lock")
                    self.assertEqual(self.subject._jobs, {})
                    self.assertEqual(retained.request, {})
                    self.assertIsNone(retained.response)
                    self.assertIsNone(retained.authorize)
                finally:
                    release.set()
                self.assertIn("error", self.finish(thread, outcome))
                if actor:
                    actor.join(2)
                    self.assertFalse(actor.is_alive())
                    if stage == "claim":
                        self.assertEqual(actor_result.get("result"), {"job": None})
                    else:
                        self.assertIn("error", actor_result)
                self.subject.heartbeat(self.heartbeat())

    def test_paused_admission_close_cannot_requeue_after_callback_returns(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        def authorization():
            entered.set()
            release.wait(5)
            return True
        thread, outcome = self.start(authorize=authorization)
        self.assertTrue(entered.wait(2))
        self.subject.close()
        release.set()
        self.assertIn("error", self.finish(thread, outcome))
        self.assertEqual(self.subject._jobs, {})
        self.assertFalse(self.subject.status()["enabled"])

    def test_huge_integer_completion_is_terminal_without_overflow_or_retention(self):
        huge = 10 ** 399
        for variant in ("elapsed_seconds", "eval_count", "confidence"):
            with self.subTest(variant=variant):
                payload = {"task": "document_classification", "input": "Synthetic document"} if variant == "confidence" else REQUEST
                thread, outcome = self.start(payload=payload)
                retained = self.queued()[0]
                job = self.claim()
                completion = self.completion(job)
                if variant == "confidence":
                    completion["response"]["result"] = {"document_type": "unknown", "reason": "Uncertain", "warnings": [], "confidence": huge}
                else:
                    completion["response"]["metrics"] = {variant: huge}
                with self.assertRaises(gateway.Unavailable):
                    self.subject.complete(completion)
                self.assertIn("error", self.finish(thread, outcome))
                self.assertEqual(retained.request, {})
                self.assertIsNone(retained.response)
                self.assertEqual(self.subject._jobs, {})
        with self.assertRaises(gateway.Unavailable):
            gateway._result(gateway.TASKS["document_classification"], {"document_type": "unknown", "reason": "Uncertain", "confidence": huge})

    def test_lone_surrogates_fail_at_shared_input_context_and_result_boundaries(self):
        for payload in ({**REQUEST, "input": "\ud800"}, {**REQUEST, "context": {"text": "\udfff"}},
                        {**REQUEST, "baseline": {"\ud800": "invalid key"}}):
            with self.assertRaises(gateway.InvalidRequest) as error:
                self.subject.assist(payload, "Admin", lambda: True, scope_id="session")
            self.assertEqual(error.exception.code, "invalid_unicode")
            self.assertEqual(self.subject._jobs, {})
        for key in ("body", "warnings"):
            thread, outcome = self.start()
            self.queued()
            job = self.claim()
            completion = self.completion(job)
            completion["response"]["result"][key] = ["\ud800"] if key == "warnings" else "\ud800"
            with self.assertRaises(gateway.Unavailable):
                self.subject.complete(completion)
            self.assertIn("error", self.finish(thread, outcome))
            with self.assertRaises(gateway.Unavailable):
                gateway._result(gateway.TASKS[REQUEST["task"]], completion["response"]["result"])

    def test_original_deadline_caps_admission_and_claim_budget(self):
        with self.assertRaises(gateway.Unavailable):
            self.subject.assist(REQUEST, "Admin", lambda: True, scope_id="session", deadline=self.clock())
        for extension, expected in ((20, 20), (900, 90)):
            thread, outcome = self.start(deadline=self.clock() + extension)
            self.queued()
            job = self.claim()
            self.assertEqual(job["expiresInSeconds"], expected)
            self.subject.complete(self.completion(job))
            self.assertIn("result", self.finish(thread, outcome))
        for deadline in (True, float("nan"), float("inf"), 10 ** 399):
            with self.assertRaises(gateway.InvalidRequest):
                self.subject.assist(REQUEST, "Admin", lambda: True, scope_id="session", deadline=deadline)

    def test_plaintext_or_alternative_credentials_are_rejected(self):
        self.assertTrue(self.subject.authenticate_worker("Bearer " + TOKEN))
        for header in (TOKEN, "Basic " + TOKEN, "Bearer wrong", "Bearer " + TOKEN + " ", "Bearer é", None):
            self.assertFalse(self.subject.authenticate_worker(header))
        self.assertNotIn(TOKEN, repr(self.subject.settings))

    def test_invalid_heartbeat_cannot_refresh_readiness(self):
        for changes in ({"local": 1}, {"ready": 1}, {"modelDigest": "b" * 64}, {"model": "remote"}, {"hostedFallbackEnabled": True}):
            with self.assertRaises(gateway.InvalidRequest):
                self.subject.heartbeat(self.heartbeat(**changes))
        self.clock.advance(15)
        self.assertFalse(self.subject.status()["available"])

    def test_disabled_relay_never_admits_or_claims(self):
        self.subject.gateway_settings = dataclasses.replace(self.subject.gateway_settings, enabled=False)
        with self.assertRaises(gateway.Unavailable):
            self.subject.assist(REQUEST, "Admin", lambda: True, scope_id="session")
        with self.assertRaises(gateway.Unavailable):
            self.subject.claim(self.identity())
        self.assertFalse(self.subject.status()["enabled"])


class RelayConfigurationTests(unittest.TestCase):
    def test_factory_requires_explicit_identity_secret_and_digest(self):
        env = {"GUNNAIRE_LOCAL_AI_COMPANY_ID": COMPANY, "GUNNAIRE_LOCAL_AI_WORKER_ID": "mac",
               "GUNNAIRE_LOCAL_AI_WORKER_TOKEN": TOKEN, "GUNNAIRE_LOCAL_AI_MODEL_DIGEST": "sha256:" + DIGEST}
        relay = create_relay(env)
        self.addCleanup(relay.close)
        self.assertEqual(relay.settings.model_digest, DIGEST)
        for key in env:
            with self.subTest(key=key):
                with self.assertRaises(gateway.InvalidRequest):
                    create_relay({name: value for name, value in env.items() if name != key})

    def test_configuration_never_weakens_deadline_capacity_or_model_pin(self):
        base = {"company_id": COMPANY, "worker_id": "mac", "worker_secret": TOKEN, "model_digest": DIGEST}
        for changes in ({"job_ttl": 91}, {"heartbeat_ttl": 16}, {"max_jobs": 5}, {"max_jobs": True},
                        {"job_ttl": float("nan")}, {"worker_secret": "x" * 31}, {"worker_secret": " " + TOKEN},
                        {"worker_id": "a/b"}, {"worker_id": "a" * 65}, {"worker_secret": "a" * 513}, {"worker_secret": TOKEN + "!"}, {"worker_secret": "\ud800" * 32}, {"model": "remote"}, {"company_id": "guess"}):
            with self.subTest(changes=tuple(changes)):
                with self.assertRaises(gateway.InvalidRequest):
                    RelaySettings(**{**base, **changes})


if __name__ == "__main__":
    unittest.main()
