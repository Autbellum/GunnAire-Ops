# Implementation Status

## Completed in this package

- Model-role configuration for Devstral Small 2, gpt-oss 20B, Qwen3-Coder 30B and the existing Qwen 2.5 Coder model.
- Loopback-only Ollama client with secret/PII redaction and denied-file controls.
- Structured advisory outputs; no automatic patch application or deployment.
- Deterministic local test execution with scrubbed environments and AI-on-failure only.
- Model benchmark harness and six GunnAire-oriented benchmark cases.
- Proposed eight-zone VLAN architecture and explicit default-deny rule matrix.
- Firewall plan validator, checklist generator and Suricata EVE-log summarizer.
- macOS installation script and optional user LaunchAgent templates.
- Unit tests and CI workflow.

## Requires execution on the Mac Studio

- Pull model weights through Ollama.
- Run real throughput/quality benchmarks on the M4 Max.
- Select the winner based on measured GunnAire tasks.
- Point the local test suites at the current local checkout, including any unpushed work.
- Install optional LaunchAgents.

## Requires physical network/firewall access

- Inventory the existing network.
- Install a dedicated OPNsense appliance between the modem/ONT and managed switch.
- Configure and test VLAN trunks, access ports and wireless SSIDs.
- Stage IDS first, then promote selected high-confidence policies to IPS.
- Configure WireGuard, DNS controls, logging and update schedules.
- Validate all business integrations and recovery procedures.

## Requires Synology DSM completion

- Create a restricted firewall-log share.
- Create a separate encrypted configuration-backup share.
- Configure a dedicated least-privilege account.
- Test restore from a known-good backup.

No production system is represented as modified or protected merely because this package exists.
