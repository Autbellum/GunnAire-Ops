#!/usr/bin/env python3
"""Conservative static validator for the proposed GunnAire firewall plan.

A pass means the checked-in JSON satisfies these static safety checks. It does not
mean the plan fits the unverified physical network or has been deployed.
"""

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
SPECIAL_ZONES = {"WAN", "INTERNET", "FIREWALL", "ANY_INTERNAL"}
PROTECTED_ZONES = {"MGMT", "BUSINESS", "SERVERS", "NAS", "DEV_AI", "VPN_ADMIN"}
UNTRUSTED_ZONES = {"GUEST", "IOT"}
ADMIN_PORTS = {22, 80, 443}


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
        if self.item is not None:
            value["item"] = self.item
        return value


class Report:
    def __init__(self) -> None:
        self.findings: list[Finding] = []

    def error(self, code: str, message: str, item: str | None = None) -> None:
        self.findings.append(Finding("error", code, message, item))

    def warning(self, code: str, message: str, item: str | None = None) -> None:
        self.findings.append(Finding("warning", code, message, item))

    def info(self, code: str, message: str, item: str | None = None) -> None:
        self.findings.append(Finding("info", code, message, item))

    @property
    def error_count(self) -> int:
        return sum(item.severity == "error" for item in self.findings)

    @property
    def warning_count(self) -> int:
        return sum(item.severity == "warning" for item in self.findings)

    def as_dict(self) -> dict[str, Any]:
        return {
            "status": "pass" if self.error_count == 0 else "fail",
            "error_count": self.error_count,
            "warning_count": self.warning_count,
            "finding_count": len(self.findings),
            "findings": [item.as_dict() for item in self.findings],
        }


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValidationInputError(f"File not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationInputError(f"Invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValidationInputError(f"Expected a JSON object in {path}")
    return value


def validate_network(plan: Mapping[str, Any], report: Report) -> set[str]:
    if plan.get("status") != "proposed_only":
        report.error("NET-STATUS", "Network plan must remain proposed_only until live acceptance")
    raw_zones = plan.get("zones")
    if not isinstance(raw_zones, list) or not raw_zones:
        report.error("NET-ZONES", "Network plan requires a non-empty zones list")
        return set()

    names: set[str] = set()
    vlan_ids: set[int] = set()
    networks: list[tuple[str, ipaddress._BaseNetwork]] = []
    for raw in raw_zones:
        if not isinstance(raw, dict):
            report.error("NET-ZONE-TYPE", "Every zone must be an object")
            continue
        name = str(raw.get("name", "")).strip()
        item = name or "<unnamed>"
        if not name:
            report.error("NET-ZONE-NAME", "Zone has no name", item)
            continue
        if name in names:
            report.error("NET-ZONE-DUPLICATE", f"Duplicate zone {name}", item)
        names.add(name)
        vlan = raw.get("vlan_id")
        if type(vlan) is not int or not 1 <= vlan <= 4094:
            report.error("NET-VLAN", "VLAN ID must be 1 through 4094", item)
        elif vlan in vlan_ids:
            report.error("NET-VLAN-DUPLICATE", f"Duplicate VLAN ID {vlan}", item)
        else:
            vlan_ids.add(vlan)
        try:
            subnet = ipaddress.ip_network(str(raw.get("subnet", "")), strict=True)
        except ValueError as exc:
            report.error("NET-SUBNET", f"Invalid subnet: {exc}", item)
            continue
        if not subnet.is_private or subnet.is_loopback or subnet.is_link_local:
            report.error("NET-PUBLIC-SUBNET", f"Subnet must be private: {subnet}", item)
        try:
            gateway = ipaddress.ip_address(str(raw.get("gateway", "")))
        except ValueError as exc:
            report.error("NET-GATEWAY", f"Invalid gateway: {exc}", item)
        else:
            if gateway not in subnet:
                report.error("NET-GATEWAY-RANGE", f"Gateway {gateway} is outside {subnet}", item)
            if gateway in {subnet.network_address, subnet.broadcast_address}:
                report.error("NET-GATEWAY-HOST", f"Gateway {gateway} is not usable", item)
        for existing_name, existing in networks:
            if subnet.overlaps(existing):
                report.error("NET-OVERLAP", f"{subnet} overlaps {existing_name} ({existing})", item)
        networks.append((name, subnet))

    required = {"MGMT", "BUSINESS", "SERVERS", "NAS", "IOT", "GUEST", "DEV_AI", "VPN_ADMIN"}
    missing = sorted(required - names)
    if missing:
        report.error("NET-MISSING-ZONES", "Missing required zones: " + ", ".join(missing))

    controls = plan.get("required_controls")
    if not isinstance(controls, dict):
        report.error("NET-CONTROLS", "required_controls must be an object")
    else:
        required_true = {
            "default_deny_inter_vlan",
            "upnp_disabled",
            "nat_pmp_disabled",
            "remote_admin_requires_wireguard",
            "dns_enforcement",
            "ntp_enforcement",
            "configuration_backup_before_change",
            "physical_console_recovery",
        }
        for key in required_true:
            if controls.get(key) is not True:
                report.error("NET-CONTROL", f"Control {key} must be true", key)
        if controls.get("management_ui_from_wan") is not False:
            report.error("NET-WAN-MGMT", "management_ui_from_wan must be false")
    return names


def _ports(raw: Any, report: Report, item: str) -> set[int]:
    if not isinstance(raw, list):
        report.error("RULE-PORTS-TYPE", "ports must be an array", item)
        return set()
    result: set[int] = set()
    for value in raw:
        if type(value) is not int or not 1 <= value <= 65535:
            report.error("RULE-PORT", f"Invalid port {value!r}", item)
        elif value in result:
            report.warning("RULE-PORT-DUPLICATE", f"Duplicate port {value}", item)
        else:
            result.add(value)
    return result


def validate_rules(matrix: Mapping[str, Any], zones: set[str], report: Report) -> None:
    if matrix.get("status") != "proposed_only":
        report.error("RULE-STATUS", "Rule matrix must remain proposed_only until live acceptance")
    if matrix.get("default_action") != "DENY":
        report.error("RULE-DEFAULT", "Default firewall action must be DENY")
    raw_rules = matrix.get("rules")
    if not isinstance(raw_rules, list) or not raw_rules:
        report.error("RULE-LIST", "Rule matrix requires a non-empty rules list")
        return

    valid_zones = zones | SPECIAL_ZONES
    ids: set[str] = set()
    orders: set[int] = set()
    saw_egress_default = False
    saw_guest_isolation = False
    saw_iot_isolation = False

    for raw in raw_rules:
        if not isinstance(raw, dict):
            report.error("RULE-TYPE", "Every rule must be an object")
            continue
        rule_id = str(raw.get("id", "")).strip()
        item = rule_id or "<unnamed>"
        if not rule_id:
            report.error("RULE-ID", "Rule has no id", item)
        elif rule_id in ids:
            report.error("RULE-ID-DUPLICATE", f"Duplicate rule id {rule_id}", item)
        ids.add(rule_id)
        order = raw.get("order")
        if type(order) is not int or order < 0:
            report.error("RULE-ORDER", "Rule order must be a nonnegative integer", item)
        elif order in orders:
            report.error("RULE-ORDER-DUPLICATE", f"Duplicate rule order {order}", item)
        orders.add(order if isinstance(order, int) else -1)

        source = str(raw.get("source", ""))
        destination = str(raw.get("destination", ""))
        protocol = str(raw.get("protocol", "")).upper()
        action = str(raw.get("action", "")).upper()
        ports = _ports(raw.get("ports", []), report, item)
        for flag in ("enabled", "logging", "approval_required", "temporary"):
            if type(raw.get(flag)) is not bool:
                report.error("RULE-BOOLEAN", f"{flag} must be a boolean", item)
        enabled = raw.get("enabled") is True
        logging = raw.get("logging") is True
        approval = raw.get("approval_required") is True
        purpose = str(raw.get("purpose", "")).strip()

        if source not in valid_zones:
            report.error("RULE-SOURCE", f"Unknown source {source!r}", item)
        if destination not in valid_zones:
            report.error("RULE-DESTINATION", f"Unknown destination {destination!r}", item)
        if protocol not in ALLOWED_PROTOCOLS:
            report.error("RULE-PROTOCOL", f"Unsupported protocol {protocol!r}", item)
        if action not in ALLOWED_ACTIONS:
            report.error("RULE-ACTION", f"Unsupported action {action!r}", item)
        if protocol in {"ANY", "ICMP"} and ports:
            report.error("RULE-PROTOCOL-PORT", f"{protocol} rules must not specify ports", item)
        if action == "ALLOW" and protocol in {"TCP", "UDP", "TCP_UDP"} and not ports:
            report.error("RULE-ALLOW-NO-PORT", "Allowed TCP/UDP rule must specify ports", item)
        if not purpose:
            report.error("RULE-PURPOSE", "Rule requires a business/security purpose", item)
        if action in {"DENY", "REJECT"} and not logging:
            report.warning("RULE-DENY-NO-LOG", "Deny/reject rule should be logged", item)
        if action == "ALLOW" and source == "ANY_INTERNAL":
            report.error("RULE-BROAD-SOURCE", "ANY_INTERNAL must not be an ALLOW source", item)
        if action == "ALLOW" and destination == "ANY_INTERNAL":
            report.error("RULE-BROAD-DEST", "ANY_INTERNAL must not be an ALLOW destination", item)

        if raw.get("temporary"):
            expiry = raw.get("expires_at")
            if not isinstance(expiry, str) or not expiry:
                report.error("RULE-TEMP-EXPIRY", "Temporary rule requires expires_at", item)
            else:
                try:
                    parsed = dt.datetime.fromisoformat(expiry.replace("Z", "+00:00"))
                except ValueError:
                    report.error("RULE-TEMP-FORMAT", "expires_at must be ISO 8601", item)
                else:
                    if parsed.tzinfo is None:
                        report.error("RULE-TEMP-TZ", "expires_at must include a timezone", item)
                    elif enabled and parsed <= dt.datetime.now(dt.timezone.utc):
                        report.error("RULE-TEMP-EXPIRED", "Enabled temporary rule has expired", item)

        if source in {"WAN", "INTERNET"} and action == "ALLOW":
            if destination != "FIREWALL":
                report.error("RULE-WAN-INTERNAL", "WAN allow cannot target an internal zone", item)
            if not (protocol == "UDP" and ports == {51820} and "wireguard" in purpose.lower()):
                report.error("RULE-WAN-SERVICE", "Only the proposed WireGuard endpoint is allowed from WAN", item)
            if not approval:
                report.error("RULE-WAN-APPROVAL", "WAN allow requires explicit approval", item)
            if enabled:
                report.warning("RULE-WAN-ENABLED", "WAN WireGuard is enabled before live acceptance", item)

        if enabled and action == "ALLOW" and source in UNTRUSTED_ZONES and destination in PROTECTED_ZONES:
            report.error("RULE-LATERAL-UNTRUSTED", f"{source} cannot access protected zone {destination}", item)
        if enabled and action == "ALLOW" and destination == "FIREWALL" and ports & ADMIN_PORTS and source not in {"MGMT", "VPN_ADMIN"}:
            report.error("RULE-FIREWALL-ADMIN", "Firewall administration is limited to MGMT and VPN_ADMIN", item)
        if action == "ALLOW" and destination in {"FIREWALL", "MGMT"} and ports & ADMIN_PORTS and not approval:
            report.error("RULE-MGMT-APPROVAL", "Management access requires explicit approval", item)
        if enabled and action == "ALLOW" and destination == "INTERNET":
            if source in {"SERVERS", "NAS", "IOT"} and not raw.get("destination_alias"):
                report.error("RULE-EGRESS-ALIAS", f"{source} egress requires a destination alias", item)
            if not ports.issubset({53, 80, 123, 443, 853}):
                report.warning("RULE-EGRESS-PORT", "Internet allow includes a nonstandard port", item)

        if enabled and source == "ANY_INTERNAL" and destination == "INTERNET" and action == "DENY" and protocol == "ANY":
            saw_egress_default = True
        if enabled and source == "GUEST" and destination == "ANY_INTERNAL" and action == "DENY":
            saw_guest_isolation = True
        if enabled and source == "IOT" and destination == "ANY_INTERNAL" and action == "DENY":
            saw_iot_isolation = True

    if not saw_egress_default:
        report.error("RULE-EGRESS-DEFAULT", "Missing ANY_INTERNAL-to-INTERNET default deny")
    if not saw_guest_isolation:
        report.error("RULE-GUEST-ISOLATION", "Missing guest-to-internal deny")
    if not saw_iot_isolation:
        report.error("RULE-IOT-ISOLATION", "Missing IoT-to-internal deny")


def _positive(value: Any) -> bool:
    return type(value) in (int, float) and 0 < value < float("inf")


def validate_updates(policy: Mapping[str, Any], report: Report) -> None:
    if policy.get("status") != "proposed_only":
        report.error("UPD-STATUS", "Threat policy must remain proposed_only until live acceptance")
    firmware = policy.get("firmware")
    if not isinstance(firmware, dict):
        report.error("UPD-FIRMWARE", "firmware must be an object")
    else:
        if str(firmware.get("channel", "")).lower() != "production":
            report.error("UPD-CHANNEL", "Firmware channel must be production")
        if firmware.get("automatic_install") is not False:
            report.error("UPD-AUTO-FIRMWARE", "Firmware must not install blindly")
        for key in ("configuration_backup_required", "release_notes_review_required", "major_upgrade_requires_console_recovery"):
            if firmware.get(key) is not True:
                report.error("UPD-FIRMWARE-CONTROL", f"{key} must be true", key)
        if not _positive(firmware.get("check_interval_hours")):
            report.error("UPD-FIRMWARE-INTERVAL", "Firmware check interval must be positive")

    suricata = policy.get("suricata")
    if not isinstance(suricata, dict):
        report.error("UPD-SURICATA", "suricata must be an object")
    else:
        if suricata.get("enabled") is not True:
            report.error("UPD-SURICATA-DISABLED", "Suricata must be enabled")
        if suricata.get("initial_mode") != "IDS_ALERT_ONLY":
            report.error("UPD-IDS-STAGE", "Initial Suricata mode must be IDS_ALERT_ONLY")
        interval = suricata.get("update_interval_hours")
        stale = suricata.get("maximum_staleness_hours")
        if not _positive(interval) or not _positive(stale) or stale < interval:
            report.error("UPD-SURICATA-INTERVAL", "Suricata intervals are invalid")
        for key in ("validate_before_activate", "retain_last_known_good", "automatic_rollback_on_load_failure"):
            if suricata.get(key) is not True:
                report.error("UPD-SURICATA-CONTROL", f"{key} must be true", key)
        feeds = suricata.get("feeds")
        if not isinstance(feeds, list) or any(not isinstance(feed, dict) or type(feed.get("enabled")) is not bool for feed in feeds):
            report.error("UPD-FEED-SCHEMA", "Feeds must be objects with boolean enabled flags")
        enabled = [feed for feed in feeds if isinstance(feed, dict) and feed.get("enabled") is True] if isinstance(feeds, list) else []
        if len(enabled) < 2:
            report.error("UPD-FEEDS", "At least two threat feeds must be enabled")
        for feed in enabled:
            if feed.get("standalone_allowed") is not False:
                report.error("UPD-FEED-STANDALONE", "No single feed is standalone coverage", str(feed.get("name")))

    dns = policy.get("dns_blocking")
    if not isinstance(dns, dict):
        report.error("UPD-DNS", "dns_blocking must be an object")
    else:
        if dns.get("enabled") is not True:
            report.error("UPD-DNS-DISABLED", "DNS blocking must be enabled")
        interval = dns.get("update_interval_hours")
        stale = dns.get("maximum_staleness_hours")
        if not _positive(interval) or not _positive(stale) or stale < interval:
            report.error("UPD-DNS-INTERVAL", "DNS blocklist intervals are invalid")
        for key in ("validate_before_activate", "retain_last_known_good", "per_zone_policy"):
            if dns.get(key) is not True:
                report.error("UPD-DNS-CONTROL", f"{key} must be true", key)

    monitoring = policy.get("monitoring")
    if not isinstance(monitoring, dict):
        report.error("UPD-MONITORING", "monitoring must be an object")
    else:
        for key in ("daily_health_report", "alert_on_update_failure", "alert_on_stale_feed", "alert_on_ips_engine_stopped", "alert_on_configuration_change"):
            if monitoring.get(key) is not True:
                report.error("UPD-MONITOR-CONTROL", f"{key} must be true", key)
        if monitoring.get("local_ai_may_change_rules") is not False:
            report.error("UPD-AI-AUTHORITY", "Local AI must never change firewall rules")


def validate_all(network: Mapping[str, Any], rules: Mapping[str, Any], updates: Mapping[str, Any]) -> Report:
    report = Report()
    zones = validate_network(network, report)
    validate_rules(rules, zones, report)
    validate_updates(updates, report)
    if report.error_count == 0:
        report.info("PLAN-STATIC-PASS", "Static checks passed; live inventory, deployment, and acceptance remain required")
    return report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--network", type=Path, default=DEFAULT_NETWORK)
    parser.add_argument("--rules", type=Path, default=DEFAULT_RULES)
    parser.add_argument("--updates", type=Path, default=DEFAULT_UPDATES)
    parser.add_argument("--output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        report = validate_all(read_json(args.network), read_json(args.rules), read_json(args.updates))
        payload = {
            "schema_version": 1,
            "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            "inputs": {"network": str(args.network), "rules": str(args.rules), "updates": str(args.updates)},
            **report.as_dict(),
            "deployed": False,
        }
        rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(rendered, encoding="utf-8")
            print(args.output)
        else:
            sys.stdout.write(rendered)
        return 0 if report.error_count == 0 else 1
    except (ValidationInputError, OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
