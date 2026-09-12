"""The native import allowlist must match the canonical server schema exactly."""
from pathlib import Path
import re
import unittest
from Backend import staff_replica_contract


class StaffReplicaImportContractTests(unittest.TestCase):
    def test_native_required_optional_types_match_server(self):
        source = (Path(__file__).resolve().parents[1] / 'GunnAire Ops' / 'StaffReplicaCoreGraph.swift').read_text()
        pairs = re.findall(r'"([a-z]+)": \("([^"]*)", "([^"]*)"\)', source)
        self.assertEqual(len(pairs), len(staff_replica_contract.SPECS))
        self.assertEqual({kind: (required, optional) for kind, required, optional in pairs}, staff_replica_contract.SPECS)


if __name__ == '__main__':
    unittest.main()
