"""Independent synthetic regression oracles for staff/owner sync boundaries.

The local worker may edit the listed contracts, never this file or other tests.
No server, real company data, provider credentials or network access is used.
"""
import copy
import hashlib
import unittest

from Backend import staff_replica_contract as core
from Backend import staff_workspace_contract as owner
from Backend import cloudkit_staff_shares as sharing


def activity():
    return {
        "action": {"text": {"_0": "fixture"}},
        "actorEmail": {"null": {}},
        "detail": {"text": {"_0": "Synthetic service note"}},
        "occurredAt": {"date": {"_0": 0}},
        "serviceCallID": {"identifier": {"_0": "A1000000-0000-4000-8000-000000000001"}},
    }


class ReplicaBoundaryRegressions(unittest.TestCase):
    def test_account_record_name_rejects_invalid_unicode_and_preserves_valid_hash(self):
        for value in ('\ud800', 'before\udfffafter'):
            self.rejected(lambda: sharing.record_name(value, 'development', '0' * 64), 'account_changed')
        value = 'synthetic-account-\U0001f527'
        expected = hashlib.sha256(('gunnaire-cloudkit-account-v1\n' + sharing.CONTAINER + '\ndevelopment\n' + value).encode()).hexdigest()
        self.assertEqual(sharing.record_name(value, 'development', expected), value)

    def rejected(self, call, code):
        with self.assertRaises(core.sharing.AttemptError) as caught:
            call()
        self.assertEqual(caught.exception.code, code)
        self.assertEqual(caught.exception.status, 400)

    def test_core_huge_integers_are_typed_rejections_not_overflow(self):
        for kind in ("number", "money"):
            for value in (10 ** 400, -(10 ** 400)):
                with self.subTest(kind=kind, negative=value < 0):
                    self.rejected(lambda: core.field(value, kind), "invalid_record")

    def test_core_numeric_contract_preserves_boundaries_and_type_rules(self):
        for kind in ("number", "money"):
            for value in (0, 1.25, 1_000_000_000):
                self.assertIsNone(core.field(value, kind))
            for value in (True, "1", -1, 1_000_000_001, float("nan"), float("inf"), -float("inf")):
                with self.subTest(kind=kind, value=repr(value)):
                    self.rejected(lambda: core.field(value, kind), "invalid_record")

    def test_core_unpaired_surrogates_are_typed_rejections(self):
        for kind in ("s", "note", "email", "date"):
            for text in ("\ud800", "\udfff", "before\ud800after"):
                with self.subTest(kind=kind, text=repr(text)):
                    self.rejected(lambda: core.field(text, kind), "invalid_record")

    def test_core_valid_unicode_and_exact_utf8_limits_remain_accepted(self):
        for kind, count in (("s", 512), ("note", 4096)):
            self.assertIsNone(core.field("\U0001f527" * count, kind))
            self.rejected(lambda: core.field("\U0001f527" * (count + 1), kind), "invalid_record")
        self.assertIsNone(core.field("Service\tline\nnext\rline", "note"))
        self.assertIsNone(core.field(r'{"opaque":"\ud800"}', "note"))

    def test_owner_text_rejects_unpaired_surrogates_without_mutation(self):
        for value in ("\ud800", "\udfff", "before\ud800after"):
            fields = activity()
            fields["detail"] = {"text": {"_0": value}}
            original = copy.deepcopy(fields)
            with self.subTest(value=repr(value)):
                self.rejected(lambda: owner.validate("activity", fields), "invalid_request")
                self.assertEqual(fields, original)

    def test_owner_text_preserves_original_valid_unicode_and_opaque_json(self):
        for value in ("Heat pump \U0001f527 serviced", r'{"opaque":"\ud800"}', "x" * 1_048_576):
            fields = activity()
            fields["detail"] = {"text": {"_0": value}}
            original = copy.deepcopy(fields)
            self.assertIsNone(owner.validate("activity", fields))
            self.assertEqual(fields, original)
        fields = activity()
        fields["detail"] = {"text": {"_0": "x" * 1_048_577}}
        self.rejected(lambda: owner.validate("activity", fields), "invalid_request")


if __name__ == "__main__":
    unittest.main()
