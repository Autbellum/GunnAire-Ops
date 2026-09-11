#!/usr/bin/env python3
from __future__ import annotations
import argparse
import copy
import ipaddress
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NETWORK = ROOT / "firewall" / "network-plan.json"
RULES = ROOT / "firewall" / "rule-matrix.json"
UPDATES = ROOT / "firewall" / "threat-update-policy.json"
POLICY = ROOT / "local-ai" / "policy.json"


def read(path: Path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain an object")
    return value


def validate(network, rules, updates, policy):
    errors = []
    if network.get("status") != "proposed_only": errors.append("network status must be proposed_only")
    names, vlans, subnets = set(), set(), []
    for zone in network.get("zones", []):
        name, vlan = zone.get("name"), zone.get("vlan_id")
        if name in names: errors.append(f"duplicate zone {name}")
        if vlan in vlans: errors.append(f"duplicate VLAN {vlan}")
        names.add(name); vlans.add(vlan)
        subnet = ipaddress.ip_network(zone["subnet"], strict=True)
        gateway = ipaddress.ip_address(zone["gateway"])
        if not subnet.is_private: errors.append(f"public subnet {subnet}")
        if gateway not in subnet: errors.append(f"gateway outside subnet for {name}")
        if any(subnet.overlaps(other) for other in subnets): errors.append(f"overlapping subnet {subnet}")
        subnets.append(subnet)
    required = {"MGMT", "BUSINESS", "SERVERS", "NAS", "IOT", "GUEST", "DEV_AI", "VPN_ADMIN"}
    if names != required: errors.append("zone set does not match the required architecture")
    controls = network.get("controls", {})
    if not controls.get("default_deny_inter_vlan"): errors.append("inter-VLAN default deny is required")
    if not controls.get("default_deny_egress"): errors.append("egress default deny is required")
    if controls.get("management_ui_from_wan"): errors.append("WAN management must be disabled")

    if rules.get("status") != "proposed_only" or rules.get("default_action") != "DENY":
        errors.append("firewall plan must remain proposed-only and default-deny")
    ids = set()
    for rule in rules.get("rules", []):
        if rule["id"] in ids: errors.append(f"duplicate rule {rule['id']}")
        ids.add(rule["id"])
        if rule["source"] == "WAN" and rule["action"] == "ALLOW":
            if rule.get("enabled"): errors.append("WAN allow must remain disabled before acceptance")
            if not (rule["destination"] == "FIREWALL" and rule["protocol"] == "UDP" and rule["ports"] == [51820]):
                errors.append("only the proposed WireGuard endpoint may be allowed from WAN")
        if rule.get("enabled") and rule["action"] == "ALLOW" and rule["source"] in {"GUEST", "IOT"} and rule["destination"] in required:
            errors.append("untrusted lateral allow detected")
        if rule.get("enabled") and rule["action"] == "ALLOW" and rule["source"] in {"SERVERS", "NAS", "IOT"} and rule["destination"] == "INTERNET" and not rule.get("destination_alias"):
            errors.append("restricted egress requires a destination alias")
    for needed in {"GUEST-ISOLATION", "IOT-ISOLATION", "DEFAULT-EGRESS-DENY"}:
        if needed not in ids: errors.append(f"missing {needed}")

    if updates.get("status") != "proposed_only": errors.append("update policy must be proposed_only")
    if updates["firmware"].get("automatic_install"): errors.append("blind firmware auto-install is forbidden")
    if updates["suricata"].get("initial_mode") != "IDS_ALERT_ONLY": errors.append("Suricata must start alert-only")
    if not updates["suricata"].get("retain_last_known_good"): errors.append("last-known-good rules are required")
    if updates["monitoring"].get("local_ai_may_change_rules"): errors.append("local AI may not change rules")
    if not policy.get("loopback_only"): errors.append("local model endpoint must be loopback-only")
    if policy.get("automatic_deployment"): errors.append("automatic AI deployment is forbidden")
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    data = [read(path) for path in (NETWORK, RULES, UPDATES, POLICY)]
    errors = validate(*data)
    if errors: raise SystemExit("\n".join(errors))
    if args.self_test:
        broken = copy.deepcopy(data)
        broken[0]["zones"][1]["vlan_id"] = broken[0]["zones"][0]["vlan_id"]
        assert validate(*broken), "validator failed to reject a duplicate VLAN"
        broken = copy.deepcopy(data)
        broken[2]["monitoring"]["local_ai_may_change_rules"] = True
        assert validate(*broken), "validator failed to reject autonomous firewall changes"
        broken = copy.deepcopy(data)
        next(rule for rule in broken[1]["rules"] if rule["id"] == "WAN-WIREGUARD")["enabled"] = True
        assert validate(*broken), "validator failed to reject an enabled pre-acceptance WAN allow"
    print("infrastructure validation: PASS")


if __name__ == "__main__":
    main()
