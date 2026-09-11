from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

FIREWALL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(FIREWALL_DIR))

import suricata_report


class SuricataReportTests(unittest.TestCase):
    def test_alert_counts_and_public_ip_anonymization(self) -> None:
        events = [
            {"timestamp": "2026-09-10T10:00:00Z", "event_type": "alert", "src_ip": "10.77.20.10", "dest_ip": "8.8.8.8", "proto": "TCP", "alert": {"signature": "Synthetic C2", "category": "Trojan", "severity": 1, "action": "blocked"}},
            {"timestamp": "2026-09-10T10:01:00Z", "event_type": "alert", "src_ip": "10.77.20.10", "dest_ip": "8.8.8.8", "proto": "TCP", "alert": {"signature": "Synthetic C2", "category": "Trojan", "severity": 1, "action": "blocked"}}
        ]
        summary = suricata_report.summarize(events, anonymize_public=True, salt="test")
        self.assertEqual(summary["total_lines"], 2)
        self.assertEqual(summary["top_signatures"][0]["count"], 2)
        self.assertEqual(summary["top_sources"][0]["value"], "10.77.20.10")
        self.assertTrue(summary["top_destinations"][0]["value"].startswith("public-"))

    def test_parse_error_is_counted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "eve.json"
            path.write_text('{"event_type":"flow"}\nnot-json\n', encoding="utf-8")
            summary = suricata_report.summarize(suricata_report.iter_events(path))
            self.assertEqual(summary["total_lines"], 2)
            self.assertEqual(summary["parse_errors"], 1)

    def test_markdown_denies_automatic_authority(self) -> None:
        rendered = suricata_report.render_markdown(suricata_report.summarize([]), Path("eve.json"))
        self.assertIn("does not authorize automatic blocking", rendered)


if __name__ == "__main__":
    unittest.main()
