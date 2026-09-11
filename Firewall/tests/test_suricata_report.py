from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

FIREWALL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIREWALL))
import suricata_report


class SuricataTests(unittest.TestCase):
    def test_counts_and_anonymizes(self):
        events = [{"timestamp": "2026-09-10T10:00:00Z", "event_type": "alert", "src_ip": "10.77.20.10", "dest_ip": "8.8.8.8", "proto": "TCP", "alert": {"signature": "Synthetic C2", "category": "Trojan", "severity": 1, "action": "blocked"}}] * 2
        result = suricata_report.summarize(events, anonymize_public=True, salt="test")
        self.assertEqual(result["total_lines"], 2)
        self.assertEqual(result["top_signatures"][0]["count"], 2)
        self.assertEqual(result["top_sources"][0]["value"], "10.77.20.10")
        self.assertTrue(result["top_destinations"][0]["value"].startswith("public-"))

    def test_parse_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "eve.json"
            path.write_text('{"event_type":"flow"}\nnot-json\n')
            result = suricata_report.summarize(suricata_report.iter_events(path))
            self.assertEqual(result["parse_errors"], 1)

    def test_markdown_keeps_human_control(self):
        text = suricata_report.markdown(suricata_report.summarize([]), Path("eve.json"))
        self.assertIn("does not authorize automatic blocking", text)


if __name__ == "__main__":
    unittest.main()
