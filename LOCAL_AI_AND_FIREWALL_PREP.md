# GunnAire Local AI and Firewall Preparation Kit

Version: **1.0.0**  
Prepared: **2026-09-10**

This package implements the safe, local portion of the plan:

- Local Ollama model roles for coding, independent review, and optional challenge testing.
- A deterministic test runner that calls no AI when tests pass.
- Local-only redaction, endpoint checks, and file-access controls.
- A repeatable model benchmark based on GunnAire-style coding, authorization, and firewall tasks.
- A proposed segmented network plan, firewall rule matrix, threat-update policy, and validation tools.
- Local Suricata EVE-log summarization.
- macOS setup and optional LaunchAgent templates.
- CI tests for the tooling itself.

It deliberately does **not**:

- Change a production firewall, router, Synology, Apple account, QuickBooks account, payment provider, or CloudKit environment.
- Expose Ollama to the LAN or internet.
- Give an AI permission to merge, deploy, install firmware, open ports, or declare a failing test successful.
- Pretend the proposed VLAN addresses are approved for the existing network.

## Model roles

| Role | Default model | Purpose |
|---|---|---|
| Coder | `devstral-small-2:24b` | Code exploration, patches, tests, and routine engineering analysis |
| Reviewer | `gpt-oss:20b` | Independent risk, authorization, security, and correctness review |
| Challenger | `qwen3-coder:30b` | Optional benchmark competitor and second coding opinion |
| Triage | `qwen2.5-coder:7b` | Optional fast log classification when already installed |

Only one large model should normally be loaded at a time on a 64 GB Apple-silicon Mac.

## Start here on the Mac Studio

From the repository root:

```bash
chmod +x LocalAI/setup_local_ai.sh
LocalAI/setup_local_ai.sh --repo "$PWD" --install-all --run-benchmark
```

The script is idempotent. It checks the platform, free space, Ollama version and loopback binding before model downloads. It never requests production credentials.

Then run:

```bash
python3 LocalAI/local_ai.py doctor
python3 LocalAI/qa_runner.py list
python3 LocalAI/qa_runner.py run --suite local-tooling --repo "$PWD"
python3 Firewall/validate_plan.py
python3 Firewall/generate_checklist.py --output Firewall/DEPLOYMENT_CHECKLIST.generated.md
```

## Local Codex launcher

After setup, a guarded launcher is generated under the local application-support directory. It uses the documented local-provider flags and starts in read-only mode:

```bash
"$HOME/Library/Application Support/GunnAireLocalAI/bin/codex-local" "$PWD"
```

## Live firewall boundary

The firewall configuration remains a **proposed plan** until all of the following are known:

1. Dedicated firewall appliance and NIC layout.
2. ISP modem/ONT mode and current router responsibilities.
3. Managed switch and access-point VLAN support.
4. Complete device and service inventory.
5. Existing subnets, static addresses, DHCP reservations, VPNs and port forwards.
6. Tested connectivity requirements for GunnAire Ops, QuickBooks, Google, Apple, CloudKit, payments, Synology and local development.
7. A physical-console rollback path.

See `IMPLEMENTATION_STATUS.md` for what is completed and what still requires the actual Mac/network.
