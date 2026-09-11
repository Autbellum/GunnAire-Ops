#!/usr/bin/env python3
"""Generate a deterministic deployment checklist from the validated plan."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

import validate_plan


def box(text: str) -> str:
    return f"- [ ] {text}"


def render(network: Mapping[str, Any], rules: Mapping[str, Any], updates: Mapping[str, Any]) -> str:
    validation = validate_plan.validate_all(network, rules, updates)
    if validation.error_count:
        messages = "; ".join(item.message for item in validation.findings if item.severity == "error")
        raise validate_plan.ValidationInputError(f"Refusing to generate from an invalid plan: {messages}")
    zones = [zone for zone in network.get("zones", []) if isinstance(zone, dict)]
    all_rules = [rule for rule in rules.get("rules", []) if isinstance(rule, dict)]
    approvals = [rule for rule in all_rules if rule.get("approval_required")]
    disabled = [rule for rule in all_rules if not rule.get("enabled")]
    ids = updates.get("suricata", {})
    dns = updates.get("dns_blocking", {})

    lines = [
        "# GunnAire Firewall Deployment Checklist",
        "",
        "Generated from the checked-in proposed network, rule, and update-policy files.",
        "",
        "> This is a controlled checklist, not an importable OPNsense configuration. Proposed addresses and rules require live verification.",
        "",
        "## 1. Evidence and rollback before change",
        "",
        box("Photograph and label the modem/ONT, router, switch, access points, NAS, firewall appliance, and cables."),
        box("Export the existing router/firewall configuration and verify the backup can be opened."),
        box("Record ISP addressing, bridge/passthrough requirements, current subnets, reservations, port forwards, VPNs, and SSIDs."),
        box("Inventory every connected device and required application flow."),
        box("Confirm local-console access to the firewall and a tested physical rollback cable path."),
        box("Name a stop/rollback decision owner and schedule a maintenance window."),
        "",
        "## 2. Dedicated OPNsense appliance",
        "",
        box("Verify NIC compatibility and assign WAN/LAN interfaces by physical port and MAC address."),
        box("Install the current OPNsense production release and supported security fixes."),
        box("Create unique administrator credentials and retain emergency recovery material offline."),
        box("Disable UPnP and NAT-PMP."),
        box("Restrict the management UI to MGMT and later authenticated VPN_ADMIN clients."),
        box("Export and hash the known-good base configuration before adding VLANs."),
        "",
        "## 3. VLANs, switch, and wireless",
        "",
    ]
    for zone in zones:
        lines.append(box(f"Create {zone['name']} VLAN {zone['vlan_id']} using {zone['subnet']} only after conflict checks; {zone.get('purpose', '')}."))
    lines.extend([
        box("Configure switch trunks and access ports; migrate one device class at a time."),
        box("Map approved SSIDs to VLANs and enable guest/client isolation where supported."),
        box("Reserve infrastructure addresses and document DHCP ranges outside static blocks."),
        box("Force clients to use firewall DNS and NTP services."),
        "",
        "## 4. Firewall policy",
        "",
        box("Apply default deny between VLANs and to egress before adding explicit allows."),
        box("Create aliases for approved cloud APIs, Synology updates, and individual IoT vendors."),
        box("Implement and review actual OPNsense evaluation order and quick-rule behavior."),
        box("Enable logging for WAN, administrative, cross-zone, server, NAS, and default-deny decisions."),
    ])
    for rule in approvals:
        ports = ",".join(str(port) for port in rule.get("ports", [])) or "any"
        state = "enabled in proposal" if rule.get("enabled") else "disabled in proposal"
        lines.append(box(f"Approve {rule['id']} ({state}): {rule['source']} → {rule['destination']} {rule['protocol']}/{ports}; {rule.get('purpose', '')}."))
    lines.extend(["", "### Rules intentionally disabled", ""])
    for rule in disabled:
        lines.append(box(f"Keep {rule['id']} disabled until prerequisites are verified: {rule.get('purpose', '')}."))
    lines.extend([
        "",
        "## 5. IDS/IPS and threat updates",
        "",
        box("Enable Suricata in IDS alert-only mode on the correct parent interfaces."),
        box("Set HOME_NET to every approved internal subnet and disable incompatible hardware offloading where required."),
        box("Use multiple supported feeds; do not treat a free feed as complete standalone coverage."),
        box(f"Refresh Suricata rules every {ids.get('update_interval_hours')} hours and alert after {ids.get('maximum_staleness_hours')} hours of staleness."),
        box("Validate and compile updates before activation, retain the last-known-good ruleset, and test rollback."),
        box(f"Observe alerts for at least {ids.get('policy_promotion_observation_hours')} hours before promoting selected high-confidence signatures to drop."),
        box("Document every suppressed signature with evidence, owner, scope, and review date."),
        "",
        "## 6. DNS protection",
        "",
        box("Use Unbound as the local resolver and enable DNSSEC unless a verified incompatibility exists."),
        box("Block direct client DNS/DoT bypass except narrow documented exceptions."),
        box(f"Refresh DNS threat lists every {dns.get('update_interval_hours')} hours and alert after {dns.get('maximum_staleness_hours')} hours."),
        box("Use narrow allowlists instead of disabling protection for an entire zone."),
        "",
        "## 7. WireGuard administration",
        "",
        box("Generate unique per-device keys and maintain an owner/device/revocation inventory."),
        box("Keep the WAN WireGuard rule disabled until endpoint, routing, logs, loss/revocation, and recovery are tested."),
        box("Limit VPN_ADMIN to required administrative destinations."),
        box("Verify lost-device revocation without exposing the firewall or NAS management UI to the internet."),
        "",
        "## 8. Business acceptance",
        "",
        box("Verify GunnAire Ops sign-in, CloudKit sync, push notifications, and associated-domain callbacks."),
        box("Verify QuickBooks authorization, token refresh, callbacks/webhooks, and read/write boundaries."),
        box("Verify Google sign-in, mail/calendar workflows, and callbacks."),
        box("Verify payment handoff without unauthorized live charges or marking an invoice paid."),
        box("Verify Apple signing/notarization traffic only from approved development systems."),
        box("Verify Synology backup, restore, and log receipt with least-privilege service accounts."),
        box("Verify printers and required IoT devices without lateral access."),
        "",
        "## 9. Security validation",
        "",
        box("Run an external scan from outside the business connection; only the approved VPN endpoint may answer."),
        box("Test every prohibited cross-VLAN path and retain evidence."),
        box("Test DNS bypass, rogue DHCP resistance, client isolation, and management-interface restrictions."),
        box("Confirm Ollama remains loopback-only and is unreachable from another device."),
        box("Test failed/stale threat-feed alerts, Suricata restart, and last-known-good rollback."),
        box("Review false positives and unexplained egress before enabling additional drop policies."),
        "",
        "## 10. Accepted configuration and recovery",
        "",
        box("Export the accepted configuration and record its checksum, software version, and date."),
        box("Store encrypted copies offline and on the hardened Synology share."),
        box("Document device-to-port/VLAN assignments and administrator recovery steps."),
        box("Perform a controlled restore test or vendor-supported equivalent."),
        box("Record the go/no-go decision, unresolved risks, and responsible approver."),
        "",
        "## Acceptance statement",
        "",
        "The firewall is not production-accepted until critical checklist items are complete, prohibited paths are proven blocked, required business workflows pass, recovery evidence is retained, and every enabled WAN or administrative rule has explicit approval.",
        "",
    ])
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network", type=Path, default=validate_plan.DEFAULT_NETWORK)
    parser.add_argument("--rules", type=Path, default=validate_plan.DEFAULT_RULES)
    parser.add_argument("--updates", type=Path, default=validate_plan.DEFAULT_UPDATES)
    parser.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        output = render(validate_plan.read_json(args.network), validate_plan.read_json(args.rules), validate_plan.read_json(args.updates))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
        print(args.output)
        return 0
    except (validate_plan.ValidationInputError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
