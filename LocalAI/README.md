# Local AI Runtime

The runtime separates model roles and keeps deterministic evidence authoritative.

## Security properties

- Ollama endpoint must resolve exclusively to loopback addresses.
- Prompts and test logs are redacted before model submission.
- Sensitive environment variables are removed from test processes.
- Denied credential/signing file types cannot be read through the CLI.
- Model responses must be structured JSON and remain advisory.
- Passing suites do not call a model.
- Failing suites may call a local model only after output is redacted and bounded.
- High-risk domains force `needs_human_approval=true` in the recorded result.

## Common commands

```bash
python3 LocalAI/local_ai.py doctor
python3 LocalAI/local_ai.py ask --role coder --domain coding --prompt "Analyze this failure..."
python3 LocalAI/qa_runner.py list
python3 LocalAI/qa_runner.py run --suite backend --repo "$PWD"
python3 LocalAI/benchmark.py --roles coder reviewer challenger
```

## Codex local mode

The installer creates a read-only launcher using:

```bash
codex --oss --local-provider ollama --model devstral-small-2:24b \
  --sandbox read-only --ask-for-approval on-request
```

This reduces hosted-model use; it does not make a local model trustworthy enough to approve production security, payment, accounting, authorization, signing or deployment changes by itself.
