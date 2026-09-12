"""Synthetic regression checks for reviewed closeout defects; no model calls."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import benchmark
import local_ai
import qa_runner


class CloseoutTests(unittest.TestCase):
    def test_prohibitions_do_not_count_as_endorsements(self):
        self.assertFalse(benchmark.asserted_concept('never disable authentication', 'disable authentication'))
        self.assertTrue(benchmark.asserted_concept('never disable authentication. Then disable authentication', 'disable authentication'))

    def test_empty_suite_catalog_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'suites.json'; p.write_text('{"suites":{}}')
            with self.assertRaises(local_ai.LocalAIError): qa_runner.load_suites(p)

    def test_every_benchmark_case_is_validated(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'cases.json'
            for item in (None, [], 3, {}, {'id': '', 'prompt': 'x'}, {'id': ' ', 'prompt': 'x'},
                         {'id': [], 'prompt': 'x'}, {'id': 'x'}, {'id': 'x', 'prompt': 3}):
                p.write_text(json.dumps({'cases': [item]}))
                with self.subTest(item=item), self.assertRaises(local_ai.LocalAIError): benchmark.load_cases(p)
            p.write_text(json.dumps({'cases': [{'id': 'x', 'prompt': 'a'}] * 2}))
            with self.assertRaises(local_ai.LocalAIError): benchmark.load_cases(p)

    def test_keyword_only_and_wrong_role_cannot_score_full(self):
        case = {'required_concepts': ['deny'], 'human_approval_required': True}
        response = {'summary': 'deny', 'risk': 'high', 'needs_human_approval': True}
        self.assertLess(benchmark.score_response(case, response, 'coder')['percentage'], 100)
        response['likely_causes'] = ['A substantive triage explanation']
        self.assertLess(benchmark.score_response(case, response, 'coder')['percentage'], 100)
        response['findings'] = ['Deny unsafe modifications until reviewed']
        self.assertEqual(benchmark.score_response(case, response, 'coder')['percentage'], 100)

    def test_injected_metadata_cannot_earn_model_credit(self):
        response = {'findings': ['Substantive finding for independent review'], 'risk': 'high',
                    'needs_human_approval': True, '_local_ai_metadata': {
                        'domain': 'magic-keyword', 'model_requested_human_approval': False}}
        score = benchmark.score_response({'required_concepts': ['magic-keyword'],
                                         'human_approval_required': True}, response)
        self.assertFalse(score['required_hits']['magic-keyword'])
        self.assertFalse(score['approval_ok'])

    def test_doctor_exit_is_nonzero_for_every_nonoperational_state(self):
        for status in ('missing-required-models', 'ollama-version-unsupported', 'unavailable', 'ok'):
            with patch.object(local_ai, 'doctor', return_value={'status': status}), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(local_ai.main(['doctor']), 0 if status == 'ok' else 1)

    def test_server_version_is_enforced(self):
        config, policy = local_ai.load_config(), local_ai.load_policy()
        class Client:
            def tags(self): return [m.name for m in config.roles.values()]
            def version(self): return '0.1.0'
        self.assertEqual(local_ai.doctor(config, policy, Client())['status'], 'ollama-version-unsupported')

    def test_explicit_home_output_resolves_once(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'HOME': tmp}), contextlib.redirect_stdout(io.StringIO()):
            local_ai._emit({'synthetic': True}, Path('~/report.json'))
            self.assertEqual(json.loads((Path(tmp) / 'report.json').read_text()), {'synthetic': True})

    def test_redirect_proxy_dns_and_path_boundaries(self):
        for url in ('http://127.0.0.1:11434/path', 'http://127.0.0.1:11434?x=1',
                    'http://127.0.0.1:11434#x', 'http://example.test:11434', 'http://127.0.0.1:1234'):
            with self.subTest(url=url), self.assertRaises(local_ai.PolicyError): local_ai.OllamaClient(url)
        with self.assertRaises(local_ai.PolicyError):
            local_ai.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.test')

    def test_small_prompt_limits_remain_bounded(self):
        for limit in range(1, 100):
            self.assertLessEqual(len(local_ai.truncate_middle('x' * 300, limit)), limit)

    def test_quoted_credentials_and_exact_model_tags(self):
        self.assertNotIn('synthetic-value', local_ai.redact_text('{"refresh_token":"synthetic-value"}').text)
        self.assertFalse(local_ai.model_name_matches('gpt-oss:latest', 'gpt-oss:20b'))


if __name__ == '__main__': unittest.main()
