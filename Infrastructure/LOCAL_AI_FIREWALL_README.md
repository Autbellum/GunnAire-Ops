# GunnAire Local AI and Firewall Preparation

Version: **1.0.0**  
Status: **pre-deployment / review required**

This repository slice prepares the local-AI and firewall work discussed for GunnAire. It does not claim that model weights have been downloaded to the Mac Studio or that a production firewall, router, Synology NAS, Apple account, QuickBooks account, payment provider, or CloudKit environment has been changed.

## Local model roles

| Role | Model | Intended use |
|---|---|---|
| Primary coder | `devstral-small-2:24b` | Swift, Python, tests, codebase exploration, routine engineering analysis |
| Independent reviewer | `gpt-oss:20b` | Security, authorization, accounting, payment, CloudKit, VPN and release-risk review |
| Optional challenger | `qwen3-coder:30b` | Alternative coding analysis and benchmark comparison |
| Fast triage | `qwen2.5-coder:7b` | Log classification and compact failure summaries |

Stable Diffusion remains separate and is used only for image-generation work.

## Security boundaries

- Ollama must remain bound to a loopback address, not the LAN or internet.
- Local model output is advisory and may not merge, push, deploy, sign, notarize, charge a customer, mark an invoice paid, open a port, install firewall firmware, or change production firewall rules.
- Deterministic test process exit codes remain authoritative.
- Production credentials, signing keys, provisioning profiles and payment secrets must not be placed in prompts.
- Authentication, authorization, accounting, payments, CloudKit, VPN, firewall, signing, deployment and recovery changes require human approval and stronger review.

## Mac Studio setup

Run from the repository root:

```bash
chmod +x Infrastructure/install-local-ai.sh
Infrastructure/install-local-ai.sh --install-core
```

To include the optional coding challenger and existing triage model:

```bash
Infrastructure/install-local-ai.sh --install-all
```

The installer checks macOS, Ollama, Codex CLI, loopback binding, minimum Ollama version and free storage. It creates a guarded local Codex launcher under:

```text
~/Library/Application Support/GunnAireLocalAI/bin/codex-local
```

The launcher starts Codex in local Ollama mode, read-only sandboxing and approval-on-request mode.

## Proposed network segmentation

The checked-in plan uses a private planning supernet and eight zones:

- `MGMT` — firewall, switch and access-point administration.
- `BUSINESS` — trusted office Macs, iPads and business systems.
- `SERVERS` — GunnAire application and backend services.
- `NAS` — Synology storage, encrypted backups and retained logs.
- `IOT` — printers, thermostats, cameras and constrained devices.
- `GUEST` — internet-only guest access with client isolation.
- `DEV_AI` — Xcode, Ollama and testing systems.
- `VPN_ADMIN` — authenticated WireGuard administrators.

The live firewall must be a dedicated OPNsense appliance between the ISP modem/ONT and a VLAN-capable managed switch. The Synology DS925+ is for storage, backups and logs—not the perimeter gateway.

## Threat-update policy

- OPNsense production channel; check daily, but do not blindly auto-install firmware.
- Back up configuration and preserve a physical-console recovery path before firmware changes.
- Start Suricata in IDS alert-only mode.
- Refresh Suricata rules every four hours, validate before activation, retain the last-known-good ruleset and roll back on load failure.
- Use multiple feeds; do not treat one free ruleset as complete coverage.
- Refresh Unbound DNS blocklists daily, validate them before activation and keep a narrow business allowlist.
- Local AI may summarize logs but may not change firewall rules.

## Validation

```bash
python3 Infrastructure/validate-infrastructure.py
python3 Infrastructure/validate-infrastructure.py --self-test
```

A passing static check means only that the proposed JSON satisfies the repository guardrails. It does not prove compatibility with the actual ISP, modem, switch, wireless access points, devices or business integrations.

## Live deployment prerequisites

Before cutover, inventory the existing network, confirm the dedicated firewall appliance and NIC layout, verify VLAN support on the switch and access points, document every static address/DHCP reservation/VPN/port forward, test GunnAire Ops and provider integrations, and retain a known-good rollback configuration.
