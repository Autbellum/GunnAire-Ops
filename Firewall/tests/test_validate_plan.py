from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

FIREWALL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIREWALL_DIR))

import validate_plan


class ValidatePlanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.network = validate_plan.read_json(validate_plan.DEFAULT_NETWORK)
        self.rules = validate_plan.read_json(validate_plan.DEFAULT_RULES)
        self.updates = validate_plan.read_json(validate_plan.DEFAULT_UPDATES)

    def codes(self, report: validate_plan.Report) -> set[str]:
        return {item.code for item in report.findings}

    def test_proposed_plan_passes(self) -> None:
        report = validate_plan.validate_all(self.network, self.rules, self.updates)
        self.assertEqual(report.error_count, 0, [item.as_dict() for item in report.findings])
        self.assertEqual(report.warning_count, 0, [item.as_dict() for item in report.findings])

    def test_boolean_ports_vlans_and_rule_flags_fail(self) -> None:
        self.network['zones'][0]['vlan_id'] = True
        self.rules['rules'][0]['ports'] = [True, []]
        self.rules['rules'][0]['enabled'] = 'false'
        codes = self.codes(validate_plan.validate_all(self.network, self.rules, self.updates))
        self.assertTrue({'NET-VLAN', 'RULE-PORT', 'RULE-BOOLEAN'} <= codes)

    def test_disabled_threat_engines_and_malformed_feeds_fail(self) -> None:
        self.updates['suricata']['enabled'] = False
        self.updates['dns_blocking']['enabled'] = False
        self.updates['suricata']['feeds'] = {'enabled': True}
        codes = self.codes(validate_plan.validate_all(self.network, self.rules, self.updates))
        self.assertTrue({'UPD-SURICATA-DISABLED', 'UPD-DNS-DISABLED', 'UPD-FEED-SCHEMA'} <= codes)

    def test_internet_source_cannot_bypass_wan_controls(self) -> None:
        self.rules['rules'].append({
            'id': 'BAD-INTERNET', 'order': 9999, 'enabled': True,
            'source': 'INTERNET', 'destination': 'NAS', 'protocol': 'TCP',
            'ports': [443], 'action': 'ALLOW', 'logging': True,
            'purpose': 'unsafe', 'approval_required': False, 'temporary': False,
        })
        codes = self.codes(validate_plan.validate_all(self.network, self.rules, self.updates))
        self.assertTrue({'RULE-WAN-INTERNAL', 'RULE-WAN-SERVICE', 'RULE-WAN-APPROVAL'} <= codes)

    def test_enabled_expired_rule_and_unapproved_management_fail(self) -> None:
        rule = next(r for r in self.rules['rules'] if r['id'] == 'DEV-040')
        rule.update(enabled=True, expires_at='2000-01-01T00:00:00Z')
        rule.update(destination='FIREWALL', ports=[443], approval_required=False)
        codes = self.codes(validate_plan.validate_all(self.network, self.rules, self.updates))
        self.assertTrue({'RULE-TEMP-EXPIRED', 'RULE-MGMT-APPROVAL'} <= codes)

    def test_overlapping_subnets_fail(self) -> None:
        network = copy.deepcopy(self.network)
        network["zones"][1]["subnet"] = network["zones"][0]["subnet"]
        network["zones"][1]["gateway"] = "10.77.10.2"
        self.assertIn("NET-OVERLAP", self.codes(validate_plan.validate_all(network, self.rules, self.updates)))

    def test_duplicate_vlan_fails(self) -> None:
        network = copy.deepcopy(self.network)
        network["zones"][1]["vlan_id"] = network["zones"][0]["vlan_id"]
        self.assertIn("NET-VLAN-DUPLICATE", self.codes(validate_plan.validate_all(network, self.rules, self.updates)))

    def test_wan_to_internal_allow_fails(self) -> None:
        rules = copy.deepcopy(self.rules)
        rules["rules"].append({
            "id": "BAD-WAN", "order": 11, "enabled": True, "source": "WAN", "destination": "NAS",
            "protocol": "TCP", "ports": [5000], "action": "ALLOW", "logging": False,
            "purpose": "unsafe", "approval_required": False, "temporary": False
        })
        codes = self.codes(validate_plan.validate_all(self.network, rules, self.updates))
        self.assertIn("RULE-WAN-INTERNAL", codes)
        self.assertIn("RULE-WAN-SERVICE", codes)
        self.assertIn("RULE-WAN-APPROVAL", codes)

    def test_iot_lateral_allow_fails(self) -> None:
        rules = copy.deepcopy(self.rules)
        rules["rules"].append({
            "id": "BAD-IOT", "order": 519, "enabled": True, "source": "IOT", "destination": "BUSINESS",
            "protocol": "TCP", "ports": [445], "action": "ALLOW", "logging": True,
            "purpose": "unsafe lateral access", "approval_required": True, "temporary": False
        })
        self.assertIn("RULE-LATERAL-UNTRUSTED", self.codes(validate_plan.validate_all(self.network, rules, self.updates)))

    def test_server_egress_requires_alias(self) -> None:
        rules = copy.deepcopy(self.rules)
        next(rule for rule in rules["rules"] if rule["id"] == "SRV-030").pop("destination_alias")
        self.assertIn("RULE-EGRESS-ALIAS", self.codes(validate_plan.validate_all(self.network, rules, self.updates)))

    def test_temporary_rule_requires_expiry(self) -> None:
        rules = copy.deepcopy(self.rules)
        next(rule for rule in rules["rules"] if rule["id"] == "DEV-040").pop("expires_at")
        self.assertIn("RULE-TEMP-EXPIRY", self.codes(validate_plan.validate_all(self.network, rules, self.updates)))

    def test_any_internal_allow_fails(self) -> None:
        rules = copy.deepcopy(self.rules)
        rules["rules"].append({
            "id": "BAD-ANY", "order": 850, "enabled": True, "source": "ANY_INTERNAL", "destination": "INTERNET",
            "protocol": "TCP", "ports": [443], "action": "ALLOW", "logging": True,
            "purpose": "unsafe broad access", "approval_required": True, "temporary": False
        })
        self.assertIn("RULE-BROAD-SOURCE", self.codes(validate_plan.validate_all(self.network, rules, self.updates)))

    def test_local_ai_cannot_change_rules(self) -> None:
        updates = copy.deepcopy(self.updates)
        updates["monitoring"]["local_ai_may_change_rules"] = True
        self.assertIn("UPD-AI-AUTHORITY", self.codes(validate_plan.validate_all(self.network, self.rules, updates)))

    def test_single_threat_feed_fails(self) -> None:
        updates = copy.deepcopy(self.updates)
        updates["suricata"]["feeds"] = updates["suricata"]["feeds"][:1]
        self.assertIn("UPD-FEEDS", self.codes(validate_plan.validate_all(self.network, self.rules, updates)))

    def test_blind_firmware_install_fails(self) -> None:
        updates = copy.deepcopy(self.updates)
        updates["firmware"]["automatic_install"] = True
        self.assertIn("UPD-AUTO-FIRMWARE", self.codes(validate_plan.validate_all(self.network, self.rules, updates)))

    def test_ips_must_start_alert_only(self) -> None:
        updates = copy.deepcopy(self.updates)
        updates["suricata"]["initial_mode"] = "DROP_ALL"
        self.assertIn("UPD-IDS-STAGE", self.codes(validate_plan.validate_all(self.network, self.rules, updates)))


if __name__ == "__main__":
    unittest.main()
