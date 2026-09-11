# GunnAire Firewall Preparation

This directory contains a **proposed**, statically validated design for a dedicated OPNsense gateway. It is not an OPNsense XML import and must not be copied blindly into production.

## Architecture

The Synology DS925+ remains a storage, backup, and retained-log system. A dedicated appliance belongs between the ISP modem/ONT and the managed switch. Proposed zones are:

- `MGMT`: firewall, switch, and access-point administration.
- `BUSINESS`: trusted office Macs, iPads, and business workstations.
- `SERVERS`: GunnAire application/backend services.
- `NAS`: Synology storage, encrypted backups, and logs.
- `IOT`: printers, thermostats, cameras, and constrained devices.
- `GUEST`: internet-only guest access with client isolation.
- `DEV_AI`: Xcode, Ollama, tests, and development systems.
- `VPN_ADMIN`: authenticated WireGuard administrators.

Inter-zone and outbound traffic defaults to deny. Only explicit business services are allowed.

## Validation and checklist

```bash
python3 Firewall/validate_plan.py
python3 Firewall/generate_checklist.py --output Firewall/DEPLOYMENT_CHECKLIST.generated.md
```

A validation pass proves only that the JSON satisfies the checked static safeguards.

## Threat updates

The proposal uses controlled OPNsense production-channel firmware updates, Suricata rule refresh every four hours with validation and last-known-good rollback, multiple feeds, Unbound DNS threat-list refresh, alert-only staging before drop policies, and alerts for failed or stale updates. Local AI may summarize; it may not alter the firewall.

Primary references:

- OPNsense IDS/IPS: https://docs.opnsense.org/manual/ips.html
- OPNsense Unbound: https://docs.opnsense.org/manual/unbound.html
- OPNsense updates: https://docs.opnsense.org/manual/updates.html
- Suricata rule management: https://docs.suricata.io/en/latest/rule-management/suricata-update.html

## Suricata reporting

```bash
python3 Firewall/suricata_report.py \
  --input /restricted/path/eve.json \
  --json-output "$HOME/Library/Logs/GunnAireFirewall/daily.json" \
  --markdown-output "$HOME/Library/Logs/GunnAireFirewall/daily.md" \
  --anonymize-public-ips
```

The summary is deterministic and cannot change rules.
