import copy
import unittest

from verify_staff_replica_vector import verify
from Backend import staff_replica_contract as contract, cloudkit_staff_shares as sharing


class StaffReplicaVectorTests(unittest.TestCase):
    def vector(self):
        identifier = "b1000000-0000-4000-8000-000000000001"
        values = {"s": "Fixture", "b": True, "email": "fixture@example.invalid", "id": identifier,
                  "ids": [identifier], "date": "2026-09-09T10:00:00Z", "number": 1, "money": 12.34}
        records = []
        for kind, (required, _) in contract.SPECS.items():
            fields = {name: values[type_name] for name, type_name in (part.split(":") for part in required.split())}
            if kind == "item": fields["reviewStatus"] = "approved"
            records.append({"kind": kind, "id": identifier, "fields": fields})
        return {"schema": contract.SCHEMA_VERSION, "coverage": contract.COVERAGE, "records": records}

    def test_exact_vector_checks_every_kind(self):
        self.assertEqual(verify(self.vector())["recordCount"], 6)

    def test_missing_or_repeated_kind_is_not_a_pass(self):
        value = self.vector(); value["records"][0] = copy.deepcopy(value["records"][1])
        with self.assertRaises(ValueError): verify(value)
        value = self.vector(); value["records"].pop()
        with self.assertRaises(ValueError): verify(value)

    def test_schema_coverage_and_unknown_envelope_fields_are_rejected(self):
        for field, result in (("schema", "full-business-v1"), ("coverage", []), ("secret", "unexpected")):
            value = self.vector(); value[field] = result
            with self.assertRaises(ValueError): verify(value)

    def test_native_private_field_or_wrong_scalar_fails_server_validation(self):
        for fields in ({"name": "Fixture", "storedPaymentMethodsJSON": "private"}, {"name": True}):
            value = self.vector(); value["records"][0]["fields"] = fields
            with self.assertRaises(sharing.AttemptError): verify(value)

    def test_noncanonical_record_identity_is_not_accepted(self):
        value = self.vector(); value["records"][0]["id"] = "foreign"
        with self.assertRaises(sharing.AttemptError): verify(value)


if __name__ == "__main__":
    unittest.main()
