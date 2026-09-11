#!/usr/bin/env python3
"""Conservative static validation for the proposed GunnAire firewall plan."""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import ipaddress
import json
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_NETWORK = BASE_DIR / "config" / "network_plan.proposed.json"
DEFAULT_RULES = BASE_DIR / "config" / "rule_matrix.proposed.json"
DEFAULT_UPDATES = BASE_DIR / "config" / "threat_update_policy.json"

ALLOWED_ACTIONS = {"ALLOW", "DENY", "REJECT"}
ALLOWED_PROTOCOLS = {"ANY", "TCP", "UDP", "TCP_UDP", "ICMP"}
SPECIAL = {"WAN", "INTERNET", "FIREWALL", "ANY_INTERNAL"}
PROTECTED = {"MGMT", "BUSINESS", "SERVERS", "NAS", "DEV_AI", "VPN_ADMIN"}
UNTRUSTED = {"GUEST", "IOT"}


class ValidationInputError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Finding:
    severity: str
    code: str
    message: str
    item: str | None = None

    def as_dict(self) -> dict[str, Any]:
        value = {"severity": self.severity, "code": self.code, "message": self.message}
        if self.item:
            value["item"] = self.item
        return value


class Report:
    def __init__(self):
        self.findings: list[Finding] = []

    def add(self, severity: str, code: str, message: str, item: str | None = None) -> None:
        self.findings.append(Finding(severity, code, message, item))

    def error(self, code: str, message: str, item: str | None = None) -> None:
        self.add("error", code, message, item)

    def warning(self, code: str, message: str, item: str | None = None) -> None:
        self.add("warning", code, message, item)

    @property
    def errors(self) -> int:
        return sum(item.severity == "error" for item in self.findings)

    @property
    def warnings(self) -> int:
        return sum(item.severity == "warning" for item in self.findings)

    def as_dict(self) -> dict[str, Any]:
        return {
            "status": "pass" if self.errors == 0 else "fail",
            "error_count": self.errors,
            "warning_count": self.warnings,
            "finding_count": len(self.findings),
            "findings": [item.as_dict() for item in self.findings],
        }


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        raise ValidationInputError(f"Cannot load {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValidationInputError(f"Expected an object in {path}")
    return value


def validate_network(plan: Mapping[str, Any], report: Report) -> set[str]:
    if plan.get("status") != "proposed_only":
        report.error("NET-STATUS", "Network plan must remain proposed_only until live acceptance")
    raw_zones = plan.get("zones")
    if not isinstance(raw_zones, list) or not raw_zones:
        report.error("NET-ZONES", "A non-empty zones list is required")
        return set()
    names: set[str] = set()
    vlans: set[int] = set()
    networks: list[tuple[str, ipaddress._BaseNetwork]] = []
    for zone in raw_zones:
        if not isinstance(zone, dict):
            report.error("NET-ZONE-TYPE", "Each zone must be an object")
            continue
        name = str(zone.get("name", "")).strip()
        item = name or "<unnamed>"
        if not name:
            report.error("NET-ZONE-NAME", "Zone name is required", item)
            continue
        if name in names:
            report.error("NET-ZONE-DUPLICATE", f"Duplicate zone {name}", item)
        names.add(name)
        vlan = zone.get("vlan_id")
        if not isinstance(vlan, int) or not 1 <= vlan <= 4094:
            report.error("NET-VLAN", "VLAN must be 1 through 4094", item)
        elif vlan in vlans:
            report.error("NET-VLAN-DUPLICATE", f"Duplicate VLAN {vlan}", item)
        else:
            vlans.add(vlan)
        try:
            subnet = ipaddress.ip_network(str(zone.get("subnet", "")), strict=True)
        except ValueError as exc:
            report.error("NET-SUBNET", f"Invalid subnet: {exc}", item)
            continue
        if not subnet.is_private or subnet.is_loopback or subnet.is_link_local:
            report.error("NET-SUBNET-PUBLIC", f"Subnet must be private: {subnet}", item)
        try:
            gateway = ipaddress.ip_address(str(zone.get("gateway", "")))
        except ValueError as exc:
            report.error("NET-GATEWAY", f"Invalid gateway: {exc}", item)
        else:
            if gateway not in subnet:
                report.error("NET-GATEWAY-RANGE", f"Gateway {gateway} is outside {subnet}", item)
            if gateway in {subnet.network_address, subnet.broadcast_address}:
                report.error("NET-GATEWAY-HOST", "Gateway is not a usable host", item)
        for existing_name, existing in networks:
            if subnet.overlaps(existing):
                report.error("NET-OVERLAP", f"{subnet} overlaps {existing_name} {existing}", item)
        networks.append((name, subnet))
    required = {"MGMT", "BUSINESS", "SERVERS", "NAS", "IOT", "GUEST", "DEV_AI", "VPN_ADMIN"}
    if required - names:
        report.error("NET-MISSING-ZONES", "Missing: " + ", ".join(sorted(required - names)))
    controls = plan.get("required_controls")
    if not isinstance(controls, dict):
        report.error("NET-CONTROLS", "required_controls must be an object")
    else:
        for key in ("default_deny_inter_vlan", "upnp_disabled", "nat_pmp_disabled", "remote_admin_requires_wireguard", "configuration_backup_before_change", "physical_console_recovery"):
            if controls.get(key) is not True:
                report.error("NET-CONTROL", f"{key} must be true", key)
        if controls.get("management_ui_from_wan") is not False:
            report.error("NET-WAN-ADMIN", "management_ui_from_wan must be false")
    return names


def _ports(value: Any, report: Report, item: str) -> set[int]:
    if not isinstance(value, list):
        report.error("RULE-PORTS", "ports must be an array", item)
        return set()
    result: set[int] = set()
    for port in value:
        if not isinstance(port, int) or not 1 <= port <= 65535:
            report.error("RULE-PORT", f"Invalid port {port!r}", item)
        elif port in result:
            report.warning("RULE-PORT-DUPLICATE", f"Duplicate port {port}", item)
        result.add(port)
    return result


def validate_rules(matrix: Mapping[str, Any], zones: set[str], report: Report) -> None:
    if matrix.get("status") != "proposed_only":
        report.error("RULE-STATUS", "Rule matrix must remain proposed_only")
    if matrix.get("default_action") != "DENY":
        report.error("RULE-DEFAULT", "Default action must be DENY")
    rules = matrix.get("rules")
    if not isinstance(rules, list) or not rules:
        report.error("RULE-LIST", "Rules list is required")
        return
    ids: set[str] = set()
    orders: set[int] = set()
    valid_zones = zones | SPECIAL
    guest_deny = iot_deny = egress_deny = False
    for rule in rules:
        if not isinstance(rule, dict):
            report.error("RULE-TYPE", "Each rule must be an object")
            continue
        rule_id = str(rule.get("id", "")).strip()
        item = rule_id or "<unnamed>"
        if not rule_id:
            report.error("RULE-ID", "Rule ID is required", item)
        elif rule_id in ids:
            report.error("RULE-ID-DUPLICATE", f"Duplicate rule ID {rule_id}", item)
        ids.add(rule_id)
        order = rule.get("order")
        if not isinstance(order, int) or order < 0:
            report.error("RULE-ORDER", "Order must be a nonnegative integer", item)
        elif order in orders:
            report.error("RULE-ORDER-DUPLICATE", f"Duplicate order {order}", item)
        orders.add(order)
        source, destination = str(rule.get("source", "")), str(rule.get("destination", ""))
        action, protocol = str(rule.get("action", "")).upper(), str(rule.get("protocol", "")).upper()
        ports = _ports(rule.get("ports", []), report, item)
        enabled, logging = bool(rule.get("enabled")), bool(rule.get("logging"))
        approval, temporary = bool(rule.get("approval_required")), bool(rule.get("temporary"))
        purpose = str(rule.get("purpose", "")).strip()
        if source not in valid_zones:
            report.error("RULE-SOURCE", f"Unknown source {source}", item)
        if destination not in valid_zones:
            report.error("RULE-DESTINATION", f"Unknown destination {destination}", item)
        if action not in ALLOWED_ACTIONS:
            report.error("RULE-ACTION", f"Invalid action {action}", item)
        if protocol not in ALLOWED_PROTOCOLS:
            report.error("RULE-PROTOCOL", f"Invalid protocol {protocol}", item)
        if protocol in {"ANY", "ICMP"} and ports:
            report.error("RULE-PROTOCOL-PORT", f"{protocol} cannot define ports", item)
        if action == "ALLOW" and protocol in {"TCP", "UDP", "TCP_UDP"} and not ports:
            report.error("RULE-ALLOW-NO-PORT", "TCP/UDP allows require ports", item)
        if not purpose:
            report.error("RULE-PURPOSE", "Purpose is required", item)
        if action in {"DENY", "REJECT"} and not logging:
            report.warning("RULE-DENY-NO-LOG", "Deny/reject should be logged", item)
        if action == "ALLOW" and source == "ANY_INTERNAL":
            report.error("RULE-BROAD-SOURCE", "ANY_INTERNAL cannot be an allow source", item)
        if action == "ALLOW" and destination == "ANY_INTERNAL":
            report.error("RULE-BROAD-DEST", "ANY_INTERNAL cannot be an allow destination", item)
        if temporary:
            expiry = rule.get("expires_at")
            if not isinstance(expiry, str):
                report.error("RULE-TEMP-EXPIRY", "Temporary rule requires expires_at", item)
            else:
                try:
                    parsed = dt.datetime.fromisoformat(expiry.replace("Z", "+00:00"))
                    if parsed.tzinfo is None:
                        raise ValueError("timezone missing")
                except ValueError:
                    report.error("RULE-TEMP-EXPIRY-FORMAT", "expires_at must be timezone-aware ISO 8601", item)
        if source == "WAN" and action == "ALLOW":
            if destination != "FIREWALL":
                report.error("RULE-WAN-INTERNAL", "WAN allow cannot target an internal zone", item)
            if protocol != "UDP" or ports != {51820} or "wireguard" not in purpose.lower():
                report.error("RULE-WAN-SERVICE", "Only proposed WireGuard UDP/51820 is permitted", item)
            if not approval:
                report.error("RULE-WAN-APPROVAL", "WAN allow requires approval", item)
            if enabled:
                report.warning("RULE-WAN-ENABLED", "WAN rule is enabled before live acceptance", item)
        if enabled and action == "ALLOW" and source in UNTRUSTED and destination in PROTECTED:
            report.error("RULE-UNTRUSTED-LATERAL", f"{source} cannot access protected {destination}", item)
        if enabled and action == "ALLOW" and destination == "FIREWALL" and ports & {22, 80, 443} and source not in {"MGMT", "VPN_ADMIN"}:
            report.error("RULE-FIREWALL-ADMIN", "Firewall admin is limited to MGMT/VPN_ADMIN", item)
        if enabled and action == "ALLOW" and destination == "INTERNET" and source in {"SERVERS", "NAS", "IOT"} and not rule.get("destination_alias"):
            report.error("RULE-EGRESS-ALIAS", f"{source} internet allow requires destination_alias", item)
        guest_deny |= enabled and source == "GUEST" and destination == "ANY_INTERNAL" and action == "DENY"
        iot_deny |= enabled and source == "IOT" and destination == "ANY_INTERNAL" and action == "DENY"
        egress_deny |= enabled and source == "ANY_INTERNAL" and destination == "INTERNET" and action == "DENY" and protocol == "ANY"
    if not guest_deny:
        report.error("RULE-GUEST-ISOLATION", "Missing guest-to-internal deny")
    if not iot_deny:
        report.error("RULE-IOT-ISOLATION", "Missing IoT-to-internal deny")
    if not egress_deny:
        report.error("RULE-EGRESS-DEFAULT", "Missing default internal egress deny")


def validate_updates(policy: Mapping[str, Any], report: Report) -> None:
    if policy.get("status") != "proposed_only":
        report.error("UPD-STATUS", "Update policy must remain proposed_only")
    firmware = policy.get("firmware")
    if not isinstance(firmware, dict):
        report.error("UPD-FIRMWARE", "Firmware policy is required")
    else:
        if str(firmware.get("channel", "")).lower() != "production":
            report.error("UPD-CHANNEL", "Firmware channel must be production")
        if firmware.get("automatic_install") is not False:
            report.error("UPD-AUTO", "Firmware must not install blindly")
        for key in ("configuration_backup_required", "release_notes_review_required", "major_upgrade_requires_console_recovery"):
            if firmware.get(key) is not True:
                report.error("UPD-FIRMWARE-CONTROL", f"{key} must be true", key)
    suricata = policy.get("suricata")
    if not isinstance(suricata, dict):
        report.error("UPD-SURICATA", "Suricata policy is required")
    else:
        if suricata.get("initial_mode") != "IDS_ALERT_ONLY":
            report.error("UPD-IDS-STAGE", "Initial mode must be IDS_ALERT_ONLY")
        if not suricata.get("validate_before_activate") or not suricata.get("retain_last_known_good") or not suricata.get("automatic_rollback_on_load_failure"):
            report.error("UPD-SURICATA-CONTROLS", "Validation, last-known-good and rollback are mandatory")
        feeds = suricata.get("feeds")
        enabled = [item for item in feeds or [] if isinstance(item, dict) and item.get("enabled")]
        if len(enabled) < 2:
            report.error("UPD-FEEDS", "At least two enabled feeds are required")
        for feed in enabled:
            if feed.get("standalone_allowed") is not False:
                report.error("UPD-FEED-STANDALONE", "No feed may be treated as complete standalone coverage", str(feed.get("name")))
        interval, stale = suricata.get("update_interval_hours"), suricata.get("maximum_staleness_hours")
        if not isinstance(interval, (int, float)) or interval <= 0 or not isinstance(stale, (int, float)) or stale < interval:
            report.error("UPD-SURICATA-INTERVAL", "Suricata update/staleness intervals are invalid")
    dns = policy.get("dns_blocking")
    if not isinstance(dns, dict) or not all(dns.get(key) is True for key in ("validate_before_activate", "retain_last_known_good", "per_zone_policy")):
        report.error("UPD-DNS", "DNS validation, last-known-good and per-zone policy are mandatory")
    monitoring = policy.get("monitoring")
    if not isinstance(monitoring, dict):
        report.error("UPD-MONITORING", "Monitoring policy is required")
    else:
        for key in ("daily_health_report", "alert_on_update_failure", "alert_on_stale_feed", "alert_on_ips_engine_stopped", "alert_on_configuration_change"):
            if monitoring.get(key) is not True:
                report.error("UPD-MONITOR-CONTROL", f"{key} must be true", key)
        if monitoring.get("local_ai_may_change_rules") is not False:
            report.error("UPD-AI-AUTHORITY", "Local AI cannot change firewall rules")


def validate_all(network: Mapping[str, Any], rules: Mapping[str, Any], updates: Mapping[str, Any]) -> Report:
    report = Report()
    zones = validate_network(network, report)
    validate_rules(rules, zones, report)
    validate_updates(updates, report)
    if report.errors == 0:
        report.add("info", "PLAN-STATIC-PASS", "Static checks passed; live inventory, hardware validation and acceptance remain required")
    return report


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network", type=Path, default=DEFAULT_NETWORK)
    parser.add_argument("--rules", type=Path, default=DEFAULT_RULES)
    parser.add_argument("--updates", type=Path, default=DEFAULT_UPDATES)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        report = validate_all(read_json(args.network), read_json(args.rules), read_json(args.updates))
        result = {
            "schema_version": 1,
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "deployed": False,
            **report.as_dict(),
        }
        text = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(text, encoding="utf-8")
            print(args.output)
        else:
            sys.stdout.write(text)
        return 0 if report.errors == 0 else 1
    except (ValidationInputError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
