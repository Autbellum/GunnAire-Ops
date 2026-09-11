from __future__ import annotations

import sys
import unittest
from pathlib import Path

FIREWALL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIREWALL))
import generate_checklist
import validate_plan


class ChecklistTests(unittest.TestCase):
    def test_contains_zones_and_acceptance(self):
        text = generate_checklist.render(
            validate_plan.read_json(validate_plan.DEFAULT_NETWORK),
            validate_plan.read_json(validate_plan.DEFAULT_RULES),
            validate_plan.read_json(validate_plan.DEFAULT_UPDATES),
        )
        for zone in ("MGMT", "BUSINESS", "SERVERS", "NAS", "IOT", "GUEST", "DEV_AI", "VPN_ADMIN"):
            self.assertIn(zone, text)
        self.assertIn("WAN-010", text)
        self.assertIn("Acceptance statement", text)


if __name__ == "__main__":
    unittest.main()
