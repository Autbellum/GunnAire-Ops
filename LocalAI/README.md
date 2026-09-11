# GunnAire Local AI Runtime

This runtime moves routine code analysis, deterministic testing, failure triage, documentation, and first-pass review onto the Mac Studio. Stable Diffusion remains separate and is used only for image-generation work.

## Model roles

| Role | Default model | Intended work |
|---|---|---|
| Coder | `devstral-small-2:24b` | Repository exploration, Swift/Python changes, test proposals, routine engineering work |
| Reviewer | `gpt-oss:20b` | Independent security, authorization, payment, accounting, CloudKit, VPN and release review |
| Challenger | `qwen3-coder:30b` | Optional alternative implementation and benchmark comparison |
| Triage | `qwen2.5-coder:7b` | Fast log classification and compact failure reports |

## Enforced boundaries

- Ollama must be reachable through loopback only. The installer also refuses a port `11434` listener exposed on a LAN interface.
- Custom endpoint hostnames, embedded credentials, endpoint paths, queries and fragments are refused.
- Prompts and failed-test logs are redacted before inference.
- Credential, signing, provisioning and secret paths are denied.
- Sensitive environment variables are removed from test processes.
- Passing suites make no model call.
- A nonzero test exit code remains failure even when a model disagrees.
- High-risk domains force human approval in the result.
- Model output remains advisory; models cannot merge, push, deploy, sign, charge, change accounting truth, open ports, install firmware or alter a production firewall.

## Installation

From the GunnAire repository root on the Mac Studio:

```bash
chmod +x LocalAI/setup_local_ai.sh
LocalAI/setup_local_ai.sh --repo "$PWD" --install-all --run-benchmark
```

The core installation pulls Devstral Small 2 and gpt-oss 20B. `--install-all` also installs Qwen3-Coder and the lightweight Qwen triage model. Only one large model should normally remain loaded while Xcode and simulators are active.

## Local Codex launchers

The installer creates:

```text
~/Library/Application Support/GunnAireLocalAI/bin/codex-local-review
~/Library/Application Support/GunnAireLocalAI/bin/codex-local-workspace
~/Library/Application Support/GunnAireLocalAI/bin/codex-local
```

- `codex-local-review` uses a read-only sandbox.
- `codex-local-workspace` permits bounded workspace edits with approval-on-request.
- `codex-local` is a compatibility alias for the read-only launcher.

Deterministic tests and independent review remain required before any locally proposed change is committed or released.

## Direct commands

```bash
python3 LocalAI/local_ai.py doctor
python3 LocalAI/qa_runner.py list
python3 LocalAI/qa_runner.py run --suite backend --repo "$PWD"
python3 LocalAI/benchmark.py --roles coder reviewer challenger
```

For longer or potentially sensitive material, use `--prompt-file` inside the approved repository rather than putting the text directly in a command-line argument. Process arguments can be visible before redaction.

Hosted review remains appropriate for difficult or consequential authentication, authorization, payment, accounting, CloudKit, signing, firewall, recovery and deployment decisions.
