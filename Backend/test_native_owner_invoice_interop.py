"""Actual Swift proposal bytes and Python receipts, without provider/database writes.

The synthetic fixture originates in the native XCTest attachment exported by
StaffOwnerInvoiceTests, then validated and receipted by this backend contract.
This tests language/domain interoperability, not HTTP authorization or live QBO.
"""
from __future__ import annotations

import copy
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

from Backend import staff_owner_invoice_applications as applications


class NativeOwnerInvoiceInteropTests(unittest.TestCase):
    def setUp(self):
        file = Path(__file__).resolve().parents[1] / "GunnAire OpsTests" / "NativeOwnerInvoiceInterop.json"
        self.vectors = json.loads(file.read_bytes())
        # Pure proposal validation with an explicit clock does not need any
        # session, database, secret, network, provider or accounting capability.
        self.service = applications.StaffOwnerInvoiceApplications(SimpleNamespace())

    def validate(self, vector, proposal=None):
        proposal = proposal or vector["proposal"]
        return self.service.validate_proposal(proposal, vector["review"],
            (proposal["companyID"], proposal["environment"], proposal["replicaID"], applications.contract.SCHEMA_VERSION),
            vector["scope"]["actorEmail"], prepared_at=vector["receipt"]["preparedAt"])

    def test_all_five_actual_native_proposals_satisfy_server_domain_contract(self):
        self.assertEqual({v["kind"] for v in self.vectors}, {"new", "discount", "catalog", "assembly", "group"})
        self.assertEqual(len(self.vectors), 5)
        for vector in self.vectors:
            with self.subTest(kind=vector["kind"]):
                self.assertTrue(self.validate(vector))

    def test_server_receipts_bind_exact_native_proposal_and_do_not_claim_qbo(self):
        for vector in self.vectors:
            expected = self.service.application_receipt(vector["proposal"], vector["scope"]["actorEmail"], vector["receipt"]["preparedAt"])
            self.assertEqual(vector["receipt"], expected)
            self.assertIs(expected["qboPublished"], False)
            self.assertIsNone(expected["publishedAt"])

    def test_discount_matches_decimal_half_up_not_binary_under_rounding(self):
        vector = next(v for v in self.vectors if v["kind"] == "discount")
        self.assertEqual(applications.atom(vector["proposal"]["invoiceFields"], "amount"), 312.07)
        damaged = copy.deepcopy(vector["proposal"])
        damaged["invoiceFields"]["amount"] = {"number": {"_0": 312.08}}
        with self.assertRaises(applications.sharing.AttemptError):
            self.validate(vector, damaged)

    def test_native_dependencies_cannot_be_omitted_or_moved_to_other_customer(self):
        vector = self.vectors[0]
        for record in vector["proposal"]["dependencies"]:
            damaged = copy.deepcopy(vector["proposal"])
            damaged["dependencies"] = [r for r in damaged["dependencies"] if (r["kind"], r["id"]) != (record["kind"], record["id"])]
            with self.assertRaises(applications.sharing.AttemptError):
                self.validate(vector, damaged)
        damaged = copy.deepcopy(vector["proposal"])
        equipment = next(r for r in damaged["dependencies"] if r["kind"] == "equipment")
        equipment["fields"]["customer"] = {"identifier": {"_0": "20000000-0000-4000-8000-000000000002"}}
        with self.assertRaises(applications.sharing.AttemptError):
            self.validate(vector, damaged)

    def test_source_hashes_and_original_staff_request_are_retained(self):
        for vector in self.vectors:
            review = vector["review"]
            self.assertEqual(review["request"], vector["proposal"]["request"])
            self.assertEqual(review["request"], review["receipt"]["request"])
            self.assertEqual(review["baseInvoiceSHA256"], applications.lines.record_hash(review["baseInvoice"]))
            self.assertEqual(review["baseItemSHA256"], applications.lines.record_hash(review["baseItem"]) if review["baseItem"] else None)

    def test_new_native_item_cannot_inherit_provider_identity(self):
        vector = self.vectors[0]
        self.assertEqual(vector["kind"], "new")
        damaged = copy.deepcopy(vector["proposal"])
        damaged["newItemFields"]["quickBooksID"] = {"text": {"_0": "UNRELATED-PROVIDER-ID"}}
        with self.assertRaises(applications.sharing.AttemptError):
            self.validate(vector, damaged)


if __name__ == "__main__":
    unittest.main()
