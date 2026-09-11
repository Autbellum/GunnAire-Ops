# GunnAire Local AI and Firewall Kit v1.0.0

This review directory carries the tested local-AI and firewall-preparation package requested for GunnAire Ops.

## What it contains

- A guarded Ollama client for local coding, independent review, and test-failure triage.
- Model roles for `devstral-small-2:24b`, `gpt-oss:20b`, optional `qwen3-coder:30b`, and lightweight `qwen2.5-coder:7b` triage.
- A macOS setup script that checks Ollama/Codex, free space, version compatibility, and loopback-only binding before model downloads.
- A deterministic test runner that does not call AI when tests pass and strips provider credentials before child test processes run.
- A six-case local model benchmark covering Swift routing, role authorization, failed tests, unsafe WAN rules, stale threat feeds, and secret handling.
- A proposed eight-zone OPNsense design, default-deny firewall rule matrix, Suricata/Unbound update policy, deployment checklist, and deterministic EVE JSON reporting.
- Safety controls preventing local models from merging, deploying, signing, charging customers, changing accounting records, changing firewall rules, opening ports, or installing firmware.

## Verification status

The isolated package verification passed:

- 20 local-AI tooling tests.
- 13 firewall tooling tests.
- 33 total tests, with zero failures or skips.
- Firewall static validation with zero errors and zero warnings.
- Three guarded QA commands, with AI not called because all commands passed.
- Bash syntax, JSON configuration, plist templates, and secret-pattern checks.

This does not claim that model weights have been installed on the Mac Studio or that a live firewall, VLAN, VPN, or Synology log target has been deployed.

## Archive integrity

The source archive is split into six 6,000-byte-or-smaller parts because this connector transports source files individually. `assemble-and-verify.sh` concatenates them, checks the archive SHA-256, extracts into a temporary directory, and runs `make verify` against the exact contents.

Archive:

`GunnAire_Local_AI_Firewall_v1.0.0.tar.xz`

SHA-256:

`64004d3e6ea8a87e3acdfc522f3e596f392f094012a5fb9eb8c8dc74f6fa60db`

## Review command

```bash
Infrastructure/LocalAIFirewall/assemble-and-verify.sh
```

## Production boundary

The branch is review-only. It does not modify GunnAire Ops runtime code, provider accounts, Apple signing, QuickBooks, Google, CloudKit, payment systems, the router, Synology DSM, or a production firewall. Live installation and cutover require the actual Mac/network equipment, completed DSM setup, a device/service inventory, and a physical rollback path.
