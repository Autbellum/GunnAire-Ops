#!/usr/bin/env python3
"""Generate a controlled deployment checklist from the proposed firewall plan."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

import validate_plan


def checkbox(text: str) -> str:
    return f"- [ ] {text}"


def render(network: Mapping[str, Any], rules: Mapping[str, Any], updates: Mapping[str, Any]) -> str:
    report = validate_plan.validate_all(network, rules, updates)
    if report.errors:
        raise validate_plan.ValidationInputError("Refusing to generate a checklist from an invalid plan")
    zones = [item for item in network["zones"] if isinstance(item, dict)]
    rule_list = [item for item in rules["rules"] if isinstance(item, dict)]
    approvals = [item for item in rule_list if item.get("approval_required")]
    disabled = [item for item in rule_list if not item.get("enabled")]
    suricata, dns = updates["suricata"], updates["dns_blocking"]
    lines = [
        "# GunnAire Firewall Deployment Checklist", "",
        "Generated from the checked-in proposed network, rule, and update-policy files.", "",
        "> This checklist is not an importable firewall configuration. Proposed addresses and rules require live verification.", "",
        "## 1. Evidence and rollback", "",
        checkbox("Photograph and label modem/ONT, router, switch, access points, NAS and every cable."),
        checkbox("Export the current router/firewall configuration and verify the backup is readable."),
        checkbox("Record ISP WAN addressing, bridge/passthrough requirements, DHCP reservations, static addresses, VPNs, port forwards and SSIDs."),
        checkbox("Confirm direct local-console access to the new firewall and a physical rollback cable path."),
        checkbox("Inventory all business devices, applications, destinations and ports."),
        checkbox("Schedule a maintenance window and name the stop/rollback decision owner."), "",
        "## 2. Dedicated OPNsense appliance", "",
        checkbox("Verify firewall NIC compatibility and assign WAN/LAN by physical MAC address."),
        checkbox("Install the current production release and supported security updates."),
        checkbox("Create unique administrator credentials and store recovery material offline."),
        checkbox("Disable UPnP and NAT-PMP."),
        checkbox("Restrict management to MGMT and, after acceptance, authenticated VPN_ADMIN clients."),
        checkbox("Export and hash the known-good base configuration."), "",
        "## 3. VLANs and DHCP", "",
    ]
    for zone in zones:
        lines.append(checkbox(f"Create {zone['name']} VLAN {zone['vlan_id']} using {zone['subnet']} only after conflict checks; {zone['purpose']}."))
    lines += [
        checkbox("Configure managed-switch trunks/access ports and migrate one device group at a time."),
        checkbox("Map wireless SSIDs to approved VLANs and enable guest/client isolation."),
        checkbox("Reserve infrastructure addresses and document DHCP ranges."),
        checkbox("Enforce firewall DNS and NTP per VLAN."), "",
        "## 4. Policy staging", "",
        checkbox("Apply default deny between VLANs before specific allows."),
        checkbox("Create aliases for business cloud APIs, Synology updates and approved IoT vendors."),
        checkbox("Confirm actual OPNsense rule evaluation order before cutover."),
        checkbox("Log WAN, cross-zone, administrative, server, NAS and default-deny rules."),
    ]
    for rule in approvals:
        ports = ",".join(map(str, rule.get("ports", []))) or "any"
        lines.append(checkbox(f"Approve {rule['id']}: {rule['source']} → {rule['destination']} {rule['protocol']}/{ports}; {rule['purpose']}."))
    lines += ["", "### Keep disabled until prerequisites pass", ""]
    for rule in disabled:
        lines.append(checkbox(f"Keep {rule['id']} disabled: {rule['purpose']}."))
    lines += [
        "", "## 5. IDS/IPS and threat intelligence", "",
        checkbox("Enable Suricata in IDS alert-only mode on the correct interfaces."),
        checkbox("Set HOME_NET to all approved internal subnets and verify offloading compatibility."),
        checkbox("Enable multiple supported feeds; never treat one free feed as complete coverage."),
        checkbox(f"Refresh signatures every {suricata['update_interval_hours']} hours and alert after {suricata['maximum_staleness_hours']} hours."),
        checkbox("Validate/compile before activation; retain and test the last-known-good rollback."),
        checkbox(f"Observe alert-only behavior for at least {suricata['policy_promotion_observation_hours']} hours before selected high-confidence drops."),
        checkbox("Document suppressed signatures with reason, owner, scope and review date."), "",
        "## 6. DNS protection", "",
        checkbox("Use Unbound locally and enable DNSSEC unless a documented compatibility issue exists."),
        checkbox("Block direct DNS/DoT bypass except narrowly approved services."),
        checkbox(f"Refresh DNS threat lists every {dns['update_interval_hours']} hours and alert after {dns['maximum_staleness_hours']} hours."),
        checkbox("Use narrow allowlist entries rather than disabling a whole VLAN policy."), "",
        "## 7. WireGuard", "",
        checkbox("Generate unique per-device keys and maintain owner/device inventory."),
        checkbox("Keep WAN-010 disabled until endpoint, keys, routing, logging and revocation are tested."),
        checkbox("Limit VPN_ADMIN to required administrative destinations."),
        checkbox("Test lost-device revocation and emergency access without exposing the management UI."), "",
        "## 8. Business workflow acceptance", "",
        checkbox("Verify GunnAire Ops sign-in, CloudKit sync, push and associated-domain callbacks."),
        checkbox("Verify QuickBooks OAuth, refresh, callback/webhook and read/write boundaries."),
        checkbox("Verify Google sign-in, mail/calendar and callback workflows."),
        checkbox("Verify payment handoff without unauthorized charges or marking invoices paid."),
        checkbox("Verify Apple signing/notarization traffic only from approved development systems."),
        checkbox("Verify Synology backup, restore and log receipt through least-privilege accounts."),
        checkbox("Verify printers/IoT without lateral access."), "",
        "## 9. Security verification", "",
        checkbox("Run an outside port scan; only the approved VPN endpoint may answer."),
        checkbox("Test every prohibited cross-VLAN path and retain results."),
        checkbox("Test DNS bypass, rogue DHCP, guest isolation and management restrictions."),
        checkbox("Confirm Ollama remains loopback-only and unreachable from another device."),
        checkbox("Test failed/stale feed alerts, Suricata restart and last-known-good rollback."),
        checkbox("Review false positives and unexplained egress before enabling new drops."), "",
        "## 10. Acceptance and recovery", "",
        checkbox("Export accepted configuration and record checksum, version and date."),
        checkbox("Store encrypted copies offline and on the hardened Synology share."),
        checkbox("Document device-to-port/VLAN assignments and administrator recovery."),
        checkbox("Perform a controlled restore validation."),
        checkbox("Record final go/no-go, unresolved risks and approver."), "",
        "## Acceptance statement", "",
        "Production acceptance requires completed critical items, verified blocked paths, passing business workflows, retained recovery evidence, and explicit approval for every enabled WAN or administrative rule.", "",
    ]
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network", type=Path, default=validate_plan.DEFAULT_NETWORK)
    parser.add_argument("--rules", type=Path, default=validate_plan.DEFAULT_RULES)
    parser.add_argument("--updates", type=Path, default=validate_plan.DEFAULT_UPDATES)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(render(validate_plan.read_json(args.network), validate_plan.read_json(args.rules), validate_plan.read_json(args.updates)), encoding="utf-8")
        print(args.output)
        return 0
    except (validate_plan.ValidationInputError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
