"""Actual QBO GroupLineDetail transactions, not flattened service substitutes.

Only fixture transports and isolated databases are used. Component quantities
are already extended; group headers have zero Amount and no separate charge.
"""
from __future__ import annotations

import copy
import json
import unittest
import urllib.parse
import uuid
from decimal import Decimal, ROUND_HALF_UP
from unittest import mock

from Backend import billing_native, billing_provider, billing_publications as billing
from Backend import gunnaire_backend as backend, qbo_link_adoption as adoption
from Backend import test_billing_assignments as assignments
from Backend import test_billing_provider as provider_fixture
from Backend.test_billing_publications import BillingFixture


def sale(identifier="I1", quantity=2, price=189, tax="NON", description="Repair labor"):
    amount = (Decimal(str(quantity)) * Decimal(str(price))).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return {"Amount": float(amount), "DetailType": "SalesItemLineDetail", "Description": description,
            "SalesItemLineDetail": {"ItemRef": {"value": identifier}, "Qty": quantity,
                                    "UnitPrice": price, "TaxCodeRef": {"value": tax}}}


def bundle():
    return {"Amount": 0, "DetailType": "GroupLineDetail", "Description": "Capacitor repair bundle",
            "GroupLineDetail": {"GroupItemRef": {"value": "G1"}, "Quantity": 2, "Line": [
                sale(), sale("M1", 4, 12.375, "TAX", "Replacement capacitor"),
                sale("M1", 2, 12.375, "TAX", "Additional capacitor")]}}


def catalog():
    return {"I1": {"Id": "I1", "Active": True, "Type": "Service", "UnitPrice": 189, "Taxable": False},
            "M1": {"Id": "M1", "Active": True, "Type": "Inventory", "UnitPrice": 12.375, "Taxable": True},
            "G1": {"Id": "G1", "Active": True, "Type": "Group", "SyncToken": "1", "Name": "Capacitor repair bundle",
                   "UnitPrice": 0, "Taxable": False, "PrintGroupedItems": True,
                   "ItemGroupDetail": {"ItemGroupLine": [
                       {"ItemRef": {"value": "I1", "type": "Service"}, "Qty": 1},
                       {"ItemRef": {"value": "M1", "type": "Inventory"}, "Qty": 2},
                       {"ItemRef": {"value": "M1", "type": "Inventory"}, "Qty": 1}]}}}


class BundleContractTests(unittest.TestCase):
    def test_order_repeated_members_and_extended_quantities_survive_canonical_roundtrip(self):
        lines = billing.line_values([bundle()])
        self.assertEqual(lines, [bundle()])
        self.assertEqual(billing.gross_amount(lines), Decimal("452.25"))
        self.assertEqual(billing.net_amount(lines), Decimal("452.25"))
        self.assertEqual(billing.catalog_identifiers(lines), {"G1", "M1", "I1"})
        self.assertEqual([line["SalesItemLineDetail"]["Qty"] for line in billing.sold_lines(lines)], [2, 4, 2])
        self.assertEqual(billing.line_values(json.loads(json.dumps(lines))), lines)

    def test_omitted_header_amount_normalizes_to_zero_not_component_total(self):
        value = bundle()
        value.pop("Amount")
        self.assertEqual(billing.line_values([value]), [bundle()])
        value["Amount"] = 452.25
        with self.assertRaises(billing.AttemptError):
            billing.line_values([value])

    def test_percentage_and_fixed_discounts_use_all_component_charges_once(self):
        for detail, amount in (({"PercentBased": True, "DiscountPercent": 10}, 45.23), ({"PercentBased": False}, 20)):
            lines = billing.line_values([bundle(), {"Amount": amount, "DetailType": "DiscountLineDetail", "DiscountLineDetail": detail}])
            self.assertEqual(billing.net_amount(lines), Decimal("452.25") - Decimal(str(amount)))

    def test_header_quantity_does_not_multiply_already_extended_lines_a_second_time(self):
        value = bundle()
        value["GroupLineDetail"]["Quantity"] = 7
        self.assertEqual(billing.gross_amount(billing.line_values([value])), Decimal("452.25"))

    def test_contract_allows_explicitly_edited_members_without_dissolving_group(self):
        value = bundle()
        value["GroupLineDetail"]["Line"] = [sale("M1", 1.25, 11.375, "TAX", "Reviewed repair option")]
        normalized = billing.line_values([value])
        self.assertEqual(normalized[0]["GroupLineDetail"]["GroupItemRef"], {"value": "G1"})
        self.assertEqual(billing.net_amount(normalized), Decimal("14.22"))

    def test_750_limit_counts_headers_components_and_discount_not_just_outer_array(self):
        value = bundle()
        value["GroupLineDetail"]["Line"] = [sale()] * 749
        self.assertEqual(len(list(billing.sold_lines(billing.line_values([value])))), 749)
        with self.assertRaises(billing.AttemptError):
            billing.line_values([value, sale()])
        with self.assertRaises(billing.AttemptError):
            billing.line_values([value, {"Amount": 0, "DetailType": "DiscountLineDetail", "DiscountLineDetail": {"PercentBased": False}}])

    def test_empty_recursive_discounted_or_wrong_type_components_are_rejected(self):
        for members in ([], None, {}, [bundle()], [{"Amount": 1, "DetailType": "DiscountLineDetail", "DiscountLineDetail": {"PercentBased": False}}],
                        [{"Amount": 0, "DetailType": "DescriptionOnly"}], [sale("G1")]):
            value = bundle()
            value["GroupLineDetail"]["Line"] = members
            with self.subTest(members=members), self.assertRaises(billing.AttemptError):
                billing.line_values([value])

    def test_missing_group_ref_wrong_quantity_property_nonfinite_and_forged_fields_fail(self):
        for changes in ({"Quantity": True}, {"Quantity": 0}, {"Quantity": -1}, {"Quantity": 0.000001},
                        {"Quantity": float("nan")}, {"Quantity": float("inf")}, {"Quantity": 1000000},
                        {"Qty": 2}, {"GroupItemRef": {"value": "../other"}}, {"GroupItemRef": None},
                        {"UnitPrice": 0}, {"TaxCodeRef": {"value": "NON"}}):
            value = bundle()
            value["GroupLineDetail"].update(changes)
            with self.subTest(changes=changes), self.assertRaises(billing.AttemptError):
                billing.line_values([value])
        for field in ("GroupItemRef", "Quantity", "Line"):
            value = bundle()
            value["GroupLineDetail"].pop(field)
            with self.assertRaises(billing.AttemptError):
                billing.line_values([value])

    def test_invalid_member_amount_precision_tax_and_hidden_second_detail_fail(self):
        for changes in ({"Amount": 379}, {"Amount": True}, {"Amount": 378.001}, {"SalesItemLineDetail": {}},
                        {"GroupLineDetail": {}}, {"DiscountLineDetail": {"PercentBased": False}}):
            value = bundle()
            value["GroupLineDetail"]["Line"][0].update(changes)
            with self.subTest(changes=changes), self.assertRaises(billing.AttemptError):
                billing.line_values([value])
        for tax in (None, "UNKNOWN", ""):
            value = bundle()
            value["GroupLineDetail"]["Line"][0]["SalesItemLineDetail"]["TaxCodeRef"] = {"value": tax}
            with self.assertRaises(billing.AttemptError):
                billing.line_values([value])

    def test_provider_nested_metadata_is_removed_but_no_sold_component_is_dropped(self):
        value = bundle()
        value.update(Id="header", LineNum=1)
        for index, member in enumerate(value["GroupLineDetail"]["Line"]):
            member.update(Id=str(index), LineNum=index + 2)
            member["SalesItemLineDetail"]["AccountRef"] = {"value": "private-account"}
        lines = [value, {"Amount": 452.25, "DetailType": "SubTotalLineDetail", "Id": "subtotal"}]
        self.assertEqual(billing.provider_line_values(lines), [bundle()])
        self.assertNotIn("private-account", json.dumps(billing.provider_line_values(lines)))

    def test_provider_duplicate_ids_across_header_members_and_other_lines_fail(self):
        for target in ("header", "member", "ordinary"):
            value = bundle()
            value["Id"] = "header"
            value["GroupLineDetail"]["Line"][0]["Id"] = "member"
            value["GroupLineDetail"]["Line"][1]["Id"] = target
            other = {**sale(), "Id": "ordinary"}
            with self.subTest(target=target), self.assertRaises(billing.AttemptError):
                billing.provider_line_values([value, other])

    def test_provider_missing_members_malformed_subtotals_and_unknown_lines_fail(self):
        for extra in ([{"Amount": 0, "DetailType": "SubTotalLineDetail"}],
                      [{"Amount": 452.25, "DetailType": "SubTotalLineDetail"}] * 2,
                      [{"Amount": 2, "DetailType": "TaxLineDetail", "TaxLineDetail": {}}]):
            with self.assertRaises(billing.AttemptError):
                billing.provider_line_values([bundle(), *extra])
        value = bundle()
        value["GroupLineDetail"].pop("Line")
        with self.assertRaises(billing.AttemptError):
            billing.provider_line_values([value])

    def test_current_field_recipe_is_ordered_and_each_leaf_has_its_own_tax_and_price(self):
        billing.verify_field_prices({"Line": [bundle()]}, catalog())
        for kind in ("price", "tax", "quantity", "order", "removed", "inactive", "type"):
            value, evidence = bundle(), catalog()
            if kind == "price": evidence["M1"]["UnitPrice"] = 13
            elif kind == "tax": evidence["M1"]["Taxable"] = False
            elif kind == "quantity": value["GroupLineDetail"]["Quantity"] = 3
            elif kind == "order": evidence["G1"]["ItemGroupDetail"]["ItemGroupLine"].reverse()
            elif kind == "removed": value["GroupLineDetail"]["Line"].pop()
            elif kind == "inactive": evidence["G1"]["Active"] = False
            elif kind == "type": evidence["G1"]["Type"] = "Service"
            with self.subTest(kind=kind), self.assertRaises(billing.AttemptError) as caught:
                billing.verify_field_prices({"Line": [value]}, evidence)
            self.assertEqual(caught.exception.code, "price_review")

    def test_catalog_recipe_rejects_recursive_category_missing_and_nonfinite_members(self):
        for changes in ({"Qty": 0}, {"Qty": True}, {"Qty": float("nan")}, {"ItemRef": {"value": "G1"}},
                        {"ItemRef": {"value": "M1", "type": "Group"}}, {"ItemRef": {"value": "M1", "type": "Category"}}):
            value = catalog()["G1"]
            value["ItemGroupDetail"]["ItemGroupLine"][0].update(changes)
            with self.subTest(changes=changes), self.assertRaises(billing.AttemptError):
                billing.group_definition(value)


class BundlePublicationTests(BillingFixture, unittest.TestCase):
    assignment = assignments.BillingAssignmentTests.assignment
    save_assignment = assignments.BillingAssignmentTests.save_assignment
    field_payload = assignments.BillingAssignmentTests.field_payload
    http = assignments.BillingAssignmentTests.http

    def setUp(self):
        super().setUp()
        self.job_id = str(uuid.uuid4())
        self.jobs = self.publisher.assignments
        self.preflight.return_value = catalog()
        with backend.db() as connection:
            for identifier in ("G1", "M1"):
                connection.execute("INSERT INTO catalog_entity_mappings VALUES (?,'realm','sandbox',?,?)",
                                   (self.company, str(uuid.uuid4()), identifier))

    def payload(self, **changes):
        value = super().payload(**changes)
        value["document"]["Line"] = [bundle()]
        address = {"Line1": "42 Fixture Street", "City": "Raleigh", "CountrySubDivisionCode": "NC", "PostalCode": "27601"}
        value["document"].update(ShipAddr=dict(address), ShipFromAddr=dict(address))
        return value

    def remote(self, document=None, **changes):
        document = document or billing.validated_request(self.payload())["document"]
        value = super().remote(document)
        total = float(billing.net_amount(document["Line"]) + Decimal("7.43"))
        return {**value, "TotalAmt": total, "Balance": total, "TxnTaxDetail": {"TotalTax": 7.43}, **changes}

    def test_office_creates_and_recovers_actual_bundle_invoice_once_with_component_tax(self):
        first, replay = self.publish(), self.publish()
        self.assertEqual(len(self.writes), 1)
        self.assertEqual(first["publication"]["id"], replay["publication"]["id"])
        self.assertEqual(first["document"]["Line"], [bundle()])
        self.assertEqual(first["document"]["TotalAmt"], 459.68)
        self.assertEqual(self.writes[0][1]["EmailStatus"], "NotSet")

    def test_dispatcher_bundle_estimate_keeps_same_structure_and_no_payment_flags(self):
        result = self.publish(self.estimate(), "Dispatcher")
        self.assertEqual(result["document"]["Line"], [bundle()])
        self.assertEqual(self.writes[0][0], "Estimate")
        self.assertFalse(any(key.startswith("AllowOnline") for key in self.writes[0][1]))

    def test_assigned_technician_publishes_current_bundle_without_office_repricing(self):
        self.save_assignment()
        result = self.publish(self.field_payload(), "Field Technician")
        self.assertEqual(result["document"]["Line"], [bundle()])
        self.assertEqual(len(self.writes), 1)

    def test_modified_bundle_needs_exact_office_review_and_keeps_changed_components(self):
        self.save_assignment()
        draft = self.field_payload()
        draft["document"]["Line"][0]["GroupLineDetail"]["Line"] = [sale("M1", 1.25, 11.375, "TAX", "Reviewed replacement")]
        self.expect("price_review", lambda: self.publish(draft, "Field Technician"))
        self.assertFalse(self.writes)
        self.publisher.approve_draft(self.admin, draft, self.email("Field Technician"))
        result = self.publish(draft, "Field Technician")
        self.assertEqual(result["document"]["Line"], draft["document"]["Line"])
        self.assertEqual(result["document"]["TotalAmt"], 21.65)

    def test_each_shared_group_and_member_mapping_is_required_in_original_scope(self):
        for identifier in ("G1", "I1", "M1"):
            with backend.db() as connection:
                connection.execute("UPDATE catalog_entity_mappings SET environment='production' WHERE provider_id=?", (identifier,))
            self.expect("item_review", self.publish)
            with backend.db() as connection:
                connection.execute("UPDATE catalog_entity_mappings SET environment='sandbox' WHERE provider_id=?", (identifier,))
        self.assertFalse(self.writes)

    def test_unknown_outcome_recovers_original_recipe_and_price_after_catalog_changes(self):
        self.save_assignment()
        self.after_write = mock.Mock(side_effect=TimeoutError("fixture lost reply"))
        with self.assertRaises(TimeoutError):
            self.publish(self.field_payload(), "Field Technician")
        self.assertEqual(self.row()["state"], "unknown")
        self.preflight.return_value["M1"]["UnitPrice"] = 99
        self.preflight.return_value["G1"]["ItemGroupDetail"]["ItemGroupLine"].pop()
        recovered = self.publisher.run(self.sessions["Field Technician"], self.row()["id"])
        self.assertEqual(recovered["document"]["Line"], [bundle()])
        self.assertEqual(len(self.writes), 1)

    def test_provider_missing_reordered_or_repriced_components_never_confirm(self):
        row = self.publisher.reserve(self.admin, self.payload())
        document = self.publisher.payload(row)
        for change in ("missing", "order", "price", "group", "quantity"):
            remote = self.remote(document)
            detail = remote["Line"][0]["GroupLineDetail"]
            if change == "missing": detail["Line"].pop()
            elif change == "order": detail["Line"].reverse()
            elif change == "price": detail["Line"][0] = sale(price=190)
            elif change == "group": detail["GroupItemRef"]["value"] = "G2"
            elif change == "quantity": detail["Quantity"] = 3
            with self.subTest(change=change), self.assertRaises(billing.AttemptError):
                self.publisher.confirm(self.admin, row["id"], remote, original_attempt=True)
        self.assertFalse(self.writes)

    def test_nested_provider_failure_stays_unknown_and_does_not_dispatch_again(self):
        def missing_component(remote):
            remote["Line"][0]["GroupLineDetail"]["Line"].pop()
            return remote
        self.after_write = missing_component
        self.expect("provider_unconfirmed", self.publish)
        self.assertEqual(self.row()["state"], "unknown")
        self.assertEqual(len(self.writes), 1)
        recovered = self.publisher.run(self.admin, self.row()["id"])
        self.assertEqual(recovered["document"]["Line"], [bundle()])
        self.assertEqual(len(self.writes), 1)

    def test_revocation_between_bundle_preflight_and_send_prevents_dispatch(self):
        self.save_assignment()
        self.before_write = lambda: self.save_assignment(self.assignment(expectedRevision=1, enabled=False))
        self.expect("review_required", lambda: self.publish(self.field_payload(), "Field Technician"))
        self.assertFalse(self.writes)

    def test_original_unpaid_invoice_update_retains_bundle_and_payment_boundary(self):
        self.publish()
        payload = self.payload(operation="update")
        payload["document"].update(Id="D1", SyncToken="0", sparse=True)
        payload["document"]["Line"][0]["GroupLineDetail"]["Line"].pop()
        result = self.publish(payload)
        self.assertEqual(result["document"]["Line"], payload["document"]["Line"])
        payload["document"]["SyncToken"] = "1"
        self.remotes[0]["Balance"] -= 1
        self.expect("payment_review", lambda: self.publish(payload))
        self.assertEqual(len(self.writes), 2)

    def test_existing_native_context_reads_all_group_components_without_financial_write(self):
        self.publish()
        native = billing_native.NativeBilling(self.publisher)
        query = {key: value for key, value in self.payload().items()
                 if key in ("companyID", "realmID", "environment", "documentType", "localDocumentID", "localCustomerID")}
        self.remotes[0]["Line"].append({"Amount": 452.25, "DetailType": "SubTotalLineDetail"})
        result = native.context(self.admin, query)
        self.assertEqual(result["document"]["Line"], [bundle()])
        self.assertEqual(len(self.writes), 1)
        self.remotes[0]["Line"][-1]["Amount"] = 0
        self.expect("provider_unconfirmed", lambda: native.context(self.admin, query))

    def test_authenticated_http_uses_real_fixed_origin_adapter_and_recovers_one_bundle_write(self):
        self.save_assignment()
        captured, records = [], []
        items = catalog()
        def transport(request):
            captured.append(request)
            url = urllib.parse.urlsplit(request.full_url)
            self.assertEqual(url.scheme, "https")
            self.assertEqual(url.hostname, "sandbox-quickbooks.api.intuit.com")
            if url.path.endswith("/preferences"):
                return {"Preferences": {"CurrencyPrefs": {"HomeCurrency": {"value": "USD"}, "MultiCurrencyEnabled": False},
                                        "TaxPrefs": {"UsingSalesTax": True, "PartnerTaxEnabled": True}}}
            if url.path.endswith("/companyinfo/realm"):
                return {"CompanyInfo": {"Id": "realm", "Country": "US"}}
            if url.path.endswith("/customer/C1"):
                return {"Customer": {"Id": "C1", "Active": True}}
            if "/item/" in url.path:
                return {"Item": copy.deepcopy(items[url.path.rsplit("/", 1)[1]])}
            if url.path.endswith("/query"):
                query = urllib.parse.parse_qs(url.query)["query"][0]
                if "COUNT(*)" in query:
                    return {"QueryResponse": {"totalCount": len(records)}}
                return {"QueryResponse": {"Invoice": copy.deepcopy(records), "startPosition": 1, "maxResults": len(records)}}
            if request.get_method() == "POST":
                self.assertEqual(url.path, "/v3/company/realm/invoice")
                document = json.loads(request.data)
                self.assertEqual(document["Line"], [bundle()])
                records.append(self.remote(document))
                return {"Invoice": copy.deepcopy(records[0])}
            if url.path.endswith("/invoice/D1"):
                return {"Invoice": copy.deepcopy(records[0])}
            self.fail("Unexpected bundle fixture resource")
        with self.http() as request, mock.patch.object(backend, "BillingQBOProvider", side_effect=lambda context, check, bearer:
                billing_provider.BillingQBOProvider(context, check, lambda *args: "fixture-bearer", transport)):
            status, result = request("/api/billing-publications", self.field_payload(), "Field Technician")
            self.assertEqual(status, 200, result)
            self.assertEqual(result["document"]["TotalAmt"], 459.68)
            items["M1"]["UnitPrice"] = 999  # Recovery must not recalculate the sold bundle.
            status, recovered = request("/api/billing-publications/" + result["publication"]["id"] + "/recover", {}, "Field Technician")
            self.assertEqual(status, 200, recovered)
            self.assertEqual(recovered["document"]["Line"], [bundle()])
            query = {key: value for key, value in self.field_payload().items()
                     if key in ("companyID", "realmID", "environment", "documentType", "localDocumentID", "localCustomerID", "serviceCallID")}
            status, current = request("/api/billing-publications/context?" + urllib.parse.urlencode(query), role="Field Technician")
            self.assertEqual(status, 200, current)
            self.assertEqual(current["document"]["Line"], [bundle()])
        self.assertEqual(sum(value.get_method() == "POST" for value in captured), 1)

    def test_existing_bundle_link_confirmation_detects_changed_recipe_without_token_change(self):
        with backend.db() as connection:
            connection.execute("DELETE FROM catalog_entity_mappings WHERE provider_id='G1'")
        self.remotes = [catalog()["G1"]]
        adopter = adoption.LinkAdopter(backend.db, self.provider, backend.encrypt_catalog_payload,
                                      backend.decrypt_catalog_payload, backend.record_audit_event)
        query = {"companyID": self.company, "realmID": "realm", "environment": "sandbox"}
        epoch = adopter.lookup(self.admin, query)["connectionRevision"]
        local = str(uuid.uuid4())
        review = adopter.preview(self.admin, {**query, "operationID": str(uuid.uuid4()), "connectionRevision": epoch,
            "links": [{"kind": "Item", "localID": local, "providerID": "G1", "localName": "Saved repair bundle"}]})
        self.remotes[0]["ItemGroupDetail"]["ItemGroupLine"][0]["Qty"] = 3
        self.expect("provider_changed", lambda: adopter.decide(self.admin, review["id"], review["revision"], confirm=True))
        with backend.db() as connection:
            self.assertIsNone(connection.execute("SELECT 1 FROM catalog_entity_mappings WHERE provider_id='G1'").fetchone())
        self.remotes = [catalog()["G1"]]
        result = adopter.decide(self.admin, review["id"], review["revision"], confirm=True)
        self.assertEqual(result["state"], "confirmed")
        with backend.db() as connection:
            self.assertEqual(connection.execute("SELECT local_item_id FROM catalog_entity_mappings WHERE provider_id='G1'").fetchone()[0], local)
        self.assertFalse(self.writes)


class BundleProviderTests(unittest.TestCase):
    setUp = provider_fixture.BillingProviderTests.setUp
    preflight_transport = provider_fixture.BillingProviderTests.preflight_transport

    def configure(self):
        self.document["Line"] = [bundle()]
        self.items = catalog()
        self.address = {"Line1": "42 Fixture Street", "City": "Raleigh", "CountrySubDivisionCode": "NC", "PostalCode": "27601"}
        self.document.update(ShipAddr=dict(self.address), ShipFromAddr=dict(self.address))
        def send(request):
            path = urllib.parse.urlsplit(request.full_url).path
            if "/item/" in path:
                return {"Item": copy.deepcopy(self.items[path.rsplit("/", 1)[1]])}
            return self.preflight_transport(request)
        self.send.side_effect = send

    def test_original_origin_reads_group_and_each_unique_leaf_once_not_one_per_repeat(self):
        self.configure()
        evidence = self.api.preflight(self.document)
        billing.verify_field_prices(self.document, evidence)
        reads = [request.args[0].full_url for request in self.send.call_args_list if "/item/" in request.args[0].full_url]
        self.assertEqual(len(reads), 3)
        self.assertEqual(set(evidence), {"G1", "I1", "M1"})
        self.assertNotIn("UnitPrice", evidence["G1"])
        self.assertEqual([line["Qty"] for line in evidence["G1"]["ItemGroupDetail"]["ItemGroupLine"]], [1, 2, 1])

    def test_taxable_member_requires_automated_tax_and_addresses_even_nontaxable_group(self):
        self.configure()
        self.document.pop("ShipFromAddr")
        with self.assertRaises(billing.AttemptError) as caught:
            self.api.preflight(self.document)
        self.assertEqual(caught.exception.code, "tax_review")
        self.document["ShipFromAddr"] = dict(self.address)
        self.preferences["TaxPrefs"]["PartnerTaxEnabled"] = False
        with self.assertRaises(billing.AttemptError):
            self.api.preflight(self.document)

    def test_inactive_group_or_leaf_and_wrong_catalog_type_fail_before_write(self):
        self.configure()
        for identifier, changes in (("G1", {"Active": False}), ("G1", {"Type": "Service"}),
                                    ("M1", {"Active": False}), ("M1", {"Type": "Group"}), ("M1", {"Type": "Category"})):
            self.items = catalog()
            self.items[identifier].update(changes)
            with self.subTest(identifier=identifier, changes=changes), self.assertRaises(billing.AttemptError):
                self.api.preflight(self.document)
        self.assertTrue(all(call.args[0].get_method() == "GET" for call in self.send.call_args_list))

    def test_wire_post_contains_exact_nested_sold_lines_and_one_claim(self):
        self.configure()
        claim = mock.Mock()
        self.send.side_effect = None
        self.send.return_value = {"Invoice": {"Id": "D1"}}
        self.api.write("Invoice", self.document, self.request_id, claim)
        claim.assert_called_once_with()
        request = self.send.call_args.args[0]
        self.assertEqual(json.loads(request.data)["Line"], [bundle()])
        self.assertEqual(request.get_method(), "POST")
        self.assertNotIn("SalesItemLineDetail", json.loads(request.data)["Line"][0])


class BundleAdoptionTests(unittest.TestCase):
    def test_bundle_mapping_review_retains_composition_and_display_choice(self):
        entry = {"kind": "Item", "providerID": "G1", "localID": str(uuid.uuid4())}
        value = adoption.evidence(entry, catalog()["G1"])
        self.assertEqual(value["Type"], "Group")
        self.assertEqual(len(value["ItemGroupDetail"]["ItemGroupLine"]), 3)
        self.assertIs(value["PrintGroupedItems"], True)
        changed = catalog()["G1"]
        changed["ItemGroupDetail"]["ItemGroupLine"].pop()
        self.assertNotEqual(adoption.digest(value), adoption.digest(adoption.evidence(entry, changed)))

    def test_invalid_bundle_display_choice_or_missing_recipe_cannot_be_adopted(self):
        entry = {"kind": "Item", "providerID": "G1", "localID": str(uuid.uuid4())}
        for changes in ({"PrintGroupedItems": "true"}, {"ItemGroupDetail": {}}, {"Type": "Category"}):
            value = {**catalog()["G1"], **changes}
            with self.subTest(changes=changes), self.assertRaises(billing.AttemptError):
                adoption.evidence(entry, value)


if __name__ == "__main__":
    unittest.main()
