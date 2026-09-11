from __future__ import annotations

import copy
import sys
import tempfile
import unittest
from pathlib import Path

FIREWALL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIREWALL_DIR))

import generate_checklist
import suricata_report
import validate_plan


class FirewallToolingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.network = validate_plan.read_json(validate_plan.DEFAULT_NETWORK)
        self.rules = validate_plan.read_json(validate_plan.DEFAULT_RULES)
        self.updates = validate_plan.read_json(validate_plan.DEFAULT_UPDATES)

    def test_proposed_plan_passes_static_validation(self) -> None:
        report = validate_plan.validate_all(self.network, self.rules, self.updates)
        self.assertEqual(report.error_count, 0, [item.to_dict() for item in report.findings])
        self.assertEqual(report.warning_count, 0, [item.to_dict() for item in report.findings])

    def test_overlapping_subnets_are_rejected(self) -> None:
        network = copy.deepcopy(self.network)
        network["zones"][1]["subnet"] = network["zones"][0]["subnet"]
        network["zones"][1]["gateway"] = "10.77.10.2"
        report = validate_plan.validate_all(network, self.rules, self.updates)
        self.assertIn("NET-OVERLAP", {item.code for item in report.findings})

    def test_duplicate_vlan_is_rejected(self) -> None:
        network = copy.deepcopy(self.network)
        network["zones"][1]["vlan_id"] = network["zones"][0]["vlan_id"]
        report = validate_plan.validate_all(network, self.rules, self.updates)
        self.assertIn("NET-VLAN-DUPLICATE", {item.code for item in report.findings})

    def test_wan_to_internal_allow_is_rejected(self) -> None:
        rules = copy.deepcopy(self.rules)
        rules["rules"].append({
            "id": "BAD-WAN",
            "order": 21,
            "enabled": True,
            "source": "WAN",
            "destination": "NAS",
            "protocol": "TCP",
            "ports": [5000],
            "action": "ALLOW",
            "logging": False,
            "purpose": "synthetic unsafe rule",
            "approval_required": False,
            "temporary": False,
        })
        report = validate_plan.validate_all(self.network, rules, self.updates)
        codes = {item.code for item in report.findings}
        self.assertIn("RULE-WAN-INTERNAL", codes)
        self.assertIn("RULE-WAN-SERVICE", codes)

    def test_untrusted_lateral_access_is_rejected(self) -> None:
        rules = copy.deepcopy(self.rules)
        rules["rules"].append({
            "id": "BAD-IOT",
            "order": 519,
            "enabled": True,
            "source": "IOT",
            "destination": "BUSINESS",
            "protocol": "TCP",
            "ports": [445],
            "action": "ALLOW",
            "logging": True,
            "purpose": "synthetic unsafe lateral rule",
            "approval_required": True,
            "temporary": False,
        })
        report = validate_plan.validate_all(self.network, rules, self.updates)
        self.assertIn("RULE-LATERAL-UNTRUSTED", {item.code for item in report.findings})

    def test_server_egress_requires_destination_alias(self) -> None:
        rules = copy.deepcopy(self.rules)
        server_rule = next(item for item in rules["rules"] if item["id"] == "SRV-030")
        server_rule.pop("destination_alias")
        report = validate_plan.validate_all(self.network, rules, self.updates)
        self.assertIn("RULE-EGRESS-ALIAS", {item.code for item in report.findings})

    def test_temporary_rule_requires_expiry(self) -> None:
        rules = copy.deepcopy(self.rules)
        temporary = next(item for item in rules["rules"] if item["id"] == "DEV-040")
        temporary.pop("expires_at")
        report = validate_plan.validate_all(self.network, rules, self.updates)
        self.assertIn("RULE-TEMP-EXPIRY", {item.code for item in report.findings})

    def test_local_ai_cannot_change_rules(self) -> None:
        updates = copy.deepcopy(self.updates)
        updates["monitoring"]["local_ai_may_change_rules"] = True
        report = validate_plan.validate_all(self.network, self.rules, updates)
        self.assertIn("UPD-AI-AUTHORITY", {item.code for item in report.findings})

    def test_multiple_threat_feeds_are_required(self) -> None:
        updates = copy.deepcopy(self.updates)
        updates["suricata"]["feeds"] = updates["suricata"]["feeds"][:1]
        report = validate_plan.validate_all(self.network, self.rules, updates)
        self.assertIn("UPD-FEEDS", {item.code for item in report.findings})

    def test_checklist_contains_all_zones_and_acceptance_gate(self) -> None:
        rendered = generate_checklist.render_checklist(self.network, self.rules, self.updates)
        for zone in ("MGMT", "BUSINESS", "SERVERS", "NAS", "IOT", "GUEST", "DEV_AI", "VPN_ADMIN"):
            self.assertIn(zone, rendered)
        self.assertIn("Required acceptance statement", rendered)
        self.assertIn("WAN-010", rendered)

    def test_suricata_summary_counts_alerts_and_anonymizes_public_ips(self) -> None:
        events = [
            {"timestamp": "2026-09-10T10:00:00Z", "event_type": "alert", "src_ip": "10.77.20.10", "dest_ip": "8.8.8.8", "proto": "TCP", "alert": {"signature": "Synthetic C2", "category": "Network Trojan", "severity": 1, "action": "blocked"}},
            {"timestamp": "2026-09-10T10:01:00Z", "event_type": "alert", "src_ip": "10.77.20.10", "dest_ip": "8.8.8.8", "proto": "TCP", "alert": {"signature": "Synthetic C2", "category": "Network Trojan", "severity": 1, "action": "blocked"}},
        ]
        summary = suricata_report.summarize(events, anonymize_public=True, anonymization_salt="test")
        self.assertEqual(summary["total_lines"], 2)
        self.assertEqual(summary["top_signatures"][0]["count"], 2)
        self.assertEqual(summary["top_sources"][0]["value"], "10.77.20.10")
        self.assertTrue(summary["top_destinations"][0]["value"].startswith("public-"))

    def test_suricata_parser_records_invalid_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "eve.json"
            path.write_text('{"event_type":"flow"}\nnot-json\n', encoding="utf-8")
            summary = suricata_report.summarize(list(suricata_report.iter_events(path)))
            self.assertEqual(summary["parse_errors"], 1)


if __name__ == "__main__":
    unittest.main()
