import json
from pathlib import Path
import re
import unittest

from Backend.generate_staff_owner_field_observation_wire_fixture import capture


class OwnerFieldObservationWireFixtureTests(unittest.TestCase):
    def test_native_fixture_matches_actual_http_contract(self):
        def stable(value):
            if type(value) is dict:
                return {key: stable(item) for key, item in value.items()}
            if type(value) is list:
                return [stable(item) for item in value]
            if type(value) is str:
                if re.fullmatch(r"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}", value):
                    return "<uuid>"
                if re.fullmatch(r"[0-9a-f]{64}", value):
                    return "<digest>"
                if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})", value):
                    return "<instant>"
            return value
        path = Path(__file__).resolve().parents[1] / "GunnAire OpsTests" / "StaffOwnerFieldObservationWireInterop.json"
        self.assertEqual(stable(json.loads(path.read_text())), stable(capture()))
