# Implementation Status

## Integrated on `main`

The core local-AI and firewall-preparation implementation is integrated in commit `5d69eada73f7ea691d2a3383212fce10103c6fa7`:

- Model-role configuration for Devstral Small 2, gpt-oss 20B, Qwen3-Coder 30B, and Qwen 2.5 Coder 7B.
- Guarded local Ollama client with prompt redaction, denied credential/signing paths, structured advisory output, and loopback-only operation.
- Deterministic local test runner with credential-scrubbed environments and AI-on-failure only.
- Six-case GunnAire model benchmark.
- Proposed eight-zone OPNsense architecture, default-deny rule matrix, threat-update policy, validator, deployment checklist, Suricata reporting, tests, and CI.

## Added on the hardening review branch

- Refuse custom Ollama hostnames, embedded endpoint credentials, endpoint paths/queries/fragments, and non-loopback port `11434` listeners.
- Fix bounded prompt behavior at very small limits and make denied path names case-insensitive.
- Check Ollama's reported version through the local API.
- Separate read-only and workspace-write local Codex launchers while retaining approval-on-request.
- Strengthen deterministic timeout handling and collision-resistant test-run IDs.
- Add regression tests for the new endpoint, path, timeout, version, and report controls.
- Add a private scheduled Suricata reporting installer that makes deterministic summaries without AI.
- Add Synology DSM hardening, Log Center, least-privilege shares/accounts, backup, snapshot, and restore preparation.

## Requires execution on the Mac Studio

- Run the installer and pull the model weights through Ollama.
- Run the real benchmark on the M4 Max and select the primary coding model from measured GunnAire tasks.
- Point suites at the active local checkout, including unpushed work.
- Install optional LaunchAgents after their paths are reviewed.
- Confirm Ollama remains unreachable from another device.

## Requires physical network/firewall access

- Inventory the current modem/ONT, router, switch, access points, subnets, devices, reservations, port forwards, VPNs, and business-service requirements.
- Install a dedicated OPNsense appliance between the modem/ONT and a VLAN-capable managed switch.
- Configure and test VLAN trunks, access ports, wireless SSIDs, DHCP, DNS, WireGuard, logging, and default-deny rules.
- Migrate one device group at a time with a physical-console rollback path.
- Stage Suricata in IDS alert-only mode, then promote only selected high-confidence policies after observation.
- Verify GunnAire Ops, QuickBooks, Google, Apple, CloudKit, payment, signing, printing, Synology, and local-development workflows.

## Requires Synology DSM completion

- Apply the checked-in DSM security preparation.
- Create separate least-privilege security-log, firewall-configuration, local-AI-report, and release-artifact targets.
- Configure snapshots and multi-version backups to the external drive plus an additional disconnected or off-site copy.
- Test Log Center reception, alerts, integrity, restore, UPS shutdown, and restricted network access.

No model installation, model benchmark, firewall cutover, VLAN migration, VPN activation, DSM change, provider mutation, live payment, signing action, or production deployment is represented as complete merely because the source and plans exist.
