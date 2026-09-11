from __future__ import annotations

import json
import unittest
from pathlib import Path

from Backend import local_ai_gateway as gateway
from LocalAI.local_ai import load_config, load_policy


ROOT = Path(__file__).resolve().parents[1]


class FakeClient:
    def __init__(self, response=None, *, installed=None, fail_tags=False, fail_chat=False):
        self.response = response or {
            "headline": "Review dispatch pressure",
            "summary": "The supplied score is unchanged.",
            "priorities": ["Review the open queue"],
            "warnings": [],
        }
        self.installed = installed or [
            "devstral-small-2:24b",
            "gpt-oss:20b",
            "qwen2.5-coder:7b",
        ]
        self.fail_tags = fail_tags
        self.fail_chat = fail_chat
        self.chat_calls = []
        self.tag_calls = 0

    def tags(self):
        self.tag_calls += 1
        if self.fail_tags:
            raise gateway.OllamaError("offline")
        return list(self.installed)

    def chat(self, **kwargs):
        self.chat_calls.append(kwargs)
        if self.fail_chat:
            raise gateway.OllamaError("offline")
        return dict(self.response), {
            "model": kwargs["model"],
            "elapsed_seconds": 0.25,
            "prompt_eval_count": 100,
            "eval_count": 20,
        }


def settings(**overrides):
    values = {
        "enabled": True,
        "endpoint": "http://127.0.0.1:11434",
        "timeout": 30,
        "max_input": 20000,
        "max_context": 12000,
        "cache_ttl": 3600,
        "cache_entries": 32,
        "concurrency": 1,
        "status_ttl": 15,
    }
    values.update(overrides)
    return gateway.Settings(**values)


def make_gateway(client: FakeClient, **setting_overrides):
    return gateway.LocalAIGateway(
        settings(**setting_overrides),
        load_config(ROOT / "LocalAI/config/models.json"),
        load_policy(ROOT / "LocalAI/config/policy.json"),
        gateway.load_routing(ROOT / "LocalAI/config/routing_policy.json"),
        client,
    )


class GatewaySettingsTests(unittest.TestCase):
    def test_defaults_are_local_first_and_enabled(self):
        value = gateway.Settings.from_env({})
        self.assertTrue(value.enabled)
        self.assertEqual(value.endpoint, "http://127.0.0.1:11434")

    def test_non_loopback_endpoint_is_rejected(self):
        with self.assertRaises(gateway.PolicyError):
            gateway.Settings.from_env({
                "GUNNAIRE_OLLAMA_ENDPOINT": "http://192.168.1.20:11434"
            })

    def test_hosted_fallback_must_remain_disabled(self):
        policy = gateway.load_routing(ROOT / "LocalAI/config/routing_policy.json")
        self.assertFalse(policy["text_and_reasoning"]["hosted_fallback_enabled"])


class LocalAIGatewayTests(unittest.TestCase):
    def test_status_reports_local_only_and_zero_hosted_credits(self):
        subject = make_gateway(FakeClient())
        value = subject.status()
        self.assertTrue(value["available"])
        self.assertTrue(value["local"])
        self.assertFalse(value["hostedFallbackEnabled"])
        self.assertEqual(value["hostedCreditsUsed"], 0)
        self.assertEqual(value["stableDiffusionScope"], "image-only")

    def test_status_is_partially_ready_when_primary_can_cover_ordinary_tasks(self):
        subject = make_gateway(FakeClient(installed=["devstral-small-2:24b"]))
        value = subject.status()
        self.assertTrue(value["available"])
        self.assertEqual(value["status"], "partially-ready")
        self.assertIn("gpt-oss:20b", value["missingModels"])
        self.assertIn("operations_narrative", value["availableTasks"])
        self.assertIn("security_review", value["unavailableTasks"])

    def test_status_fails_closed_when_ollama_is_offline(self):
        subject = make_gateway(FakeClient(fail_tags=True))
        value = subject.status()
        self.assertFalse(value["available"])
        self.assertEqual(value["status"], "unavailable")

    def test_operations_narrative_uses_primary_local_model(self):
        client = FakeClient()
        subject = make_gateway(client)
        response = subject.assist(
            {
                "task": "operations_narrative",
                "input": "Use the deterministic snapshot without changing it.",
                "context": {"score": 84, "openWork": 7},
            },
            actor_role="Admin",
        )
        self.assertEqual(client.chat_calls[0]["model"], "devstral-small-2:24b")
        self.assertEqual(response["provider"], "ollama")
        self.assertTrue(response["local"])
        self.assertEqual(response["hostedCreditsUsed"], 0)
        self.assertFalse(response["stableDiffusionUsed"])
        self.assertTrue(response["advisoryOnly"])
        self.assertTrue(response["needsHumanApproval"])
        self.assertEqual(response["result"]["headline"], "Review dispatch pressure")

    def test_document_classification_uses_triage_model(self):
        client = FakeClient(response={
            "document_type": "invoice",
            "confidence": 0.75,
            "reason": "The excerpt contains an invoice label.",
            "warnings": [],
        })
        subject = make_gateway(client)
        response = subject.assist(
            {"task": "document_classification", "input": "Invoice number 123"},
            actor_role="Accounting",
        )
        self.assertEqual(client.chat_calls[0]["model"], "qwen2.5-coder:7b")
        self.assertEqual(response["result"]["confidence"], 0.75)

    def test_triage_task_falls_back_to_primary_local_model(self):
        client = FakeClient(
            response={
                "document_type": "invoice",
                "confidence": 0.6,
                "reason": "Invoice heading.",
                "warnings": [],
            },
            installed=["devstral-small-2:24b", "gpt-oss:20b"],
        )
        subject = make_gateway(client)
        response = subject.assist(
            {"task": "document_classification", "input": "Invoice heading"},
            actor_role="Accounting",
        )
        self.assertEqual(client.chat_calls[0]["model"], "devstral-small-2:24b")
        self.assertEqual(response["hostedCreditsUsed"], 0)

    def test_security_review_uses_review_model_and_admin_role(self):
        client = FakeClient(response={
            "summary": "Review required.",
            "findings": [],
            "required_controls": [],
            "tests": [],
            "warnings": [],
        })
        subject = make_gateway(client)
        with self.assertRaises(gateway.Forbidden):
            subject.assist(
                {"task": "security_review", "input": "Review this rule."},
                actor_role="Dispatcher",
            )
        subject.assist(
            {"task": "security_review", "input": "Review this rule."},
            actor_role="Admin",
        )
        self.assertEqual(client.chat_calls[0]["model"], "gpt-oss:20b")

    def test_unknown_task_is_rejected_without_model_call(self):
        client = FakeClient()
        subject = make_gateway(client)
        with self.assertRaises(gateway.InvalidRequest):
            subject.assist({"task": "freeform", "input": "Do anything"}, actor_role="Admin")
        self.assertEqual(client.chat_calls, [])

    def test_payment_card_is_rejected_without_model_call(self):
        client = FakeClient()
        subject = make_gateway(client)
        with self.assertRaises(gateway.InvalidRequest) as caught:
            subject.assist(
                {"task": "customer_email_draft", "input": "Use card 4242 4242 4242 4242"},
                actor_role="Admin",
            )
        self.assertEqual(caught.exception.code, "prohibited_sensitive_data")
        self.assertEqual(client.chat_calls, [])

    def test_sensitive_context_key_is_rejected(self):
        subject = make_gateway(FakeClient())
        with self.assertRaises(gateway.InvalidRequest) as caught:
            subject.assist(
                {
                    "task": "operations_narrative",
                    "input": "Summarize.",
                    "context": {"refreshToken": "not-allowed"},
                },
                actor_role="Admin",
            )
        self.assertEqual(caught.exception.code, "prohibited_context_key")

    def test_email_and_phone_are_redacted_before_model_call(self):
        client = FakeClient()
        subject = make_gateway(client)
        response = subject.assist(
            {
                "task": "operations_narrative",
                "input": "Contact jane@example.com or 336-555-1212 about the queue.",
            },
            actor_role="Admin",
        )
        prompt = client.chat_calls[0]["user_prompt"]
        self.assertNotIn("jane@example.com", prompt)
        self.assertNotIn("336-555-1212", prompt)
        self.assertGreaterEqual(response["redactions"], 2)

    def test_identical_request_is_served_from_memory_cache(self):
        client = FakeClient()
        subject = make_gateway(client)
        payload = {
            "task": "operations_narrative",
            "input": "Summarize the fixed snapshot.",
            "context": {"score": 91},
        }
        first = subject.assist(payload, actor_role="Admin")
        second = subject.assist(payload, actor_role="Admin")
        self.assertFalse(first["cached"])
        self.assertTrue(second["cached"])
        self.assertEqual(len(client.chat_calls), 1)
        self.assertEqual(first["inputDigest"], second["inputDigest"])

    def test_disabled_gateway_never_calls_model(self):
        client = FakeClient()
        subject = make_gateway(client, enabled=False)
        with self.assertRaises(gateway.Unavailable) as caught:
            subject.assist(
                {"task": "operations_narrative", "input": "Summarize."},
                actor_role="Admin",
            )
        self.assertEqual(caught.exception.code, "local_ai_disabled")
        self.assertEqual(client.chat_calls, [])

    def test_invalid_model_shape_fails_closed(self):
        client = FakeClient(response={"warnings": []})
        subject = make_gateway(client)
        with self.assertRaises(gateway.Unavailable) as caught:
            subject.assist(
                {"task": "operations_narrative", "input": "Summarize."},
                actor_role="Admin",
            )
        self.assertEqual(caught.exception.code, "invalid_model_response")

    def test_request_and_response_are_json_serializable(self):
        subject = make_gateway(FakeClient())
        response = subject.assist(
            {"task": "operations_narrative", "input": "Summarize.", "context": {"score": 42}},
            actor_role="Admin",
        )
        json.dumps(response)


if __name__ == "__main__":
    unittest.main()
