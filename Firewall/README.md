# GunnAire Firewall Preparation

This directory contains a **proposed**, statically validated design for a dedicated OPNsense gateway. It is not an OPNsense XML import and must not be copied blindly into production.

The Synology DS925+ stores encrypted backups and retained logs after DSM hardening; it is not the primary firewall.

## Commands

```bash
python3 Firewall/validate_plan.py
python3 Firewall/generate_checklist.py --output Firewall/DEPLOYMENT_CHECKLIST.generated.md
python3 Firewall/suricata_report.py \
  --input /path/to/eve.json \
  --json-output "$HOME/Library/Logs/GunnAireFirewall/daily.json" \
  --markdown-output "$HOME/Library/Logs/GunnAireFirewall/daily.md" \
  --anonymize-public-ips
```

## Deployment order

Inventory and back up the current network; install a dedicated appliance with physical-console recovery; create VLANs; migrate one group at a time; apply default-deny and explicit service rules; stage IDS and DNS protection; verify every business integration; configure restricted Synology targets; then run outside exposure, segmentation, failure and restore tests.

Primary references:

- OPNsense IDS/IPS: https://docs.opnsense.org/manual/ips.html
- OPNsense Unbound: https://docs.opnsense.org/manual/unbound.html
- OPNsense updates: https://docs.opnsense.org/manual/updates.html
- Suricata rule management: https://docs.suricata.io/en/latest/rule-management/suricata-update.html
