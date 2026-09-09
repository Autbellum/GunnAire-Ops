"""Explicit native field names must target their actual matching Swift property."""
from pathlib import Path
import re
import unittest


class StaffWorkspaceModelContractTests(unittest.TestCase):
    def test_each_explicit_mapping_targets_its_named_model_property(self):
        root = Path(__file__).resolve().parents[1] / 'GunnAire Ops'
        count = 0
        for name in ('StaffWorkspaceModelCodecs.swift', 'StaffWorkspaceBillingCodecs.swift',
                     'StaffWorkspaceWorkforceCodecs.swift', 'StaffWorkspaceOperationsCodecs.swift',
                     'StaffWorkspaceFieldCodecs.swift', 'StaffWorkspaceResourceCodecs.swift'):
            source = (root / name).read_text()
            matches = re.findall(r'\.(?:value|optional|enumeration|reference)\("([^"]+)",\s*\\\.([A-Za-z0-9_]+)', source)
            self.assertGreater(len(matches), 0)
            for field, property_name in matches:
                self.assertEqual(field, property_name, (name, field, property_name))
            count += len(matches)
        self.assertEqual(count, 561)


if __name__ == '__main__':
    unittest.main()
