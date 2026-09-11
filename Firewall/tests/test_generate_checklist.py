from __future__ import annotations

import sys
import unittest
from pathlib import Path

FIREWALL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIREWALL_DIR))

import generate_checklist
import validate_plan


class ChecklistTests(unittest.TestCase):
    def test_checklist_contains_all_zones_and_acceptance(self) -> None:
        rendered = generate_checklist.render(
            validate_plan.read_json(validate_plan.DEFAULT_NETWORK),
            validate_plan.read_json(validate_plan.DEFAULT_RULES),
            validate_plan.read_json(validate_plan.DEFAULT_UPDATES),
        )
        for zone in ("MGMT", "BUSINESS", "SERVERS", "NAS", "IOT", "GUEST", "DEV_AI", "VPN_ADMIN"):
            self.assertIn(zone, rendered)
        self.assertIn("Acceptance statement", rendered)
        self.assertIn("WAN-010", rendered)
        self.assertIn("CloudKit", rendered)
        self.assertIn("QuickBooks", rendered)


if __name__ == "__main__":
    unittest.main()
