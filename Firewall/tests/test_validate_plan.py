from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

FIREWALL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIREWALL))
import validate_plan


class FirewallValidationTests(unittest.TestCase):
    def setUp(self):
        self.network = validate_plan.read_json(validate_plan.DEFAULT_NETWORK)
        self.rules = validate_plan.read_json(validate_plan.DEFAULT_RULES)
        self.updates = validate_plan.read_json(validate_plan.DEFAULT_UPDATES)

    def test_proposal_passes(self):
        report = validate_plan.validate_all(self.network, self.rules, self.updates)
        self.assertEqual(report.errors, 0, [item.as_dict() for item in report.findings])

    def test_overlap_fails(self):
        network = copy.deepcopy(self.network)
        network["zones"][1]["subnet"] = network["zones"][0]["subnet"]
        network["zones"][1]["gateway"] = "10.77.10.2"
        report = validate_plan.validate_all(network, self.rules, self.updates)
        self.assertIn("NET-OVERLAP", {item.code for item in report.findings})

    def test_duplicate_vlan_fails(self):
        network = copy.deepcopy(self.network)
        network["zones"][1]["vlan_id"] = network["zones"][0]["vlan_id"]
        report = validate_plan.validate_all(network, self.rules, self.updates)
        self.assertIn("NET-VLAN-DUPLICATE", {item.code for item in report.findings})

    def test_wan_to_nas_fails(self):
        rules = copy.deepcopy(self.rules)
        rules["rules"].append({"id": "BAD-WAN", "order": 15, "enabled": True, "source": "WAN", "destination": "NAS", "protocol": "TCP", "ports": [5000], "action": "ALLOW", "logging": False, "purpose": "bad", "approval_required": False, "temporary": False})
        report = validate_plan.validate_all(self.network, rules, self.updates)
        self.assertIn("RULE-WAN-INTERNAL", {item.code for item in report.findings})

    def test_iot_lateral_fails(self):
        rules = copy.deepcopy(self.rules)
        rules["rules"].append({"id": "BAD-IOT", "order": 515, "enabled": True, "source": "IOT", "destination": "BUSINESS", "protocol": "TCP", "ports": [445], "action": "ALLOW", "logging": True, "purpose": "bad", "approval_required": True, "temporary": False})
        report = validate_plan.validate_all(self.network, rules, self.updates)
        self.assertIn("RULE-UNTRUSTED-LATERAL", {item.code for item in report.findings})

    def test_server_egress_needs_alias(self):
        rules = copy.deepcopy(self.rules)
        next(item for item in rules["rules"] if item["id"] == "SRV-030").pop("destination_alias")
        report = validate_plan.validate_all(self.network, rules, self.updates)
        self.assertIn("RULE-EGRESS-ALIAS", {item.code for item in report.findings})

    def test_temporary_rule_needs_expiry(self):
        rules = copy.deepcopy(self.rules)
        next(item for item in rules["rules"] if item["id"] == "DEV-040").pop("expires_at")
        report = validate_plan.validate_all(self.network, rules, self.updates)
        self.assertIn("RULE-TEMP-EXPIRY", {item.code for item in report.findings})

    def test_ai_cannot_change_rules(self):
        updates = copy.deepcopy(self.updates)
        updates["monitoring"]["local_ai_may_change_rules"] = True
        report = validate_plan.validate_all(self.network, self.rules, updates)
        self.assertIn("UPD-AI-AUTHORITY", {item.code for item in report.findings})

    def test_single_feed_fails(self):
        updates = copy.deepcopy(self.updates)
        updates["suricata"]["feeds"] = updates["suricata"]["feeds"][:1]
        report = validate_plan.validate_all(self.network, self.rules, updates)
        self.assertIn("UPD-FEEDS", {item.code for item in report.findings})


if __name__ == "__main__":
    unittest.main()
