from __future__ import annotations

import copy
import json
import unittest
import uuid
from pathlib import Path
from unittest import mock

from Backend import staff_workspace_contract as contract, staff_workspace_selection as selection
from Backend import staff_workspace_field_policy as policy, staff_workspace_structured as structured
from Backend import staff_workspace_projection as projection
from Backend import staff_workspace_discriminators as discriminators
from Backend import test_staff_workspace_selections as fixtures, test_staff_billing_delivery as billing_fixtures

row, set_value = fixtures.row, fixtures.set_value


def set_json(record, field, value):
    set_value(record, field, json.dumps(value))


def rich_records(company=billing_fixtures.COMPANY, replica=billing_fixtures.REPLICA):
    records = billing_fixtures.rich_records(company, replica)
    by = {r["kind"]: r for r in records}
    instant = 810687500
    set_json(by["technician"], "serviceAreasJSON", ["Richmond", "Henrico"])
    set_json(by["technician"], "supportedEquipmentTypesJSON", dict(version=2,
        supportedEquipmentTypeRawValues=["split_system_ac"],
        reviewedAt=instant, reviewDueAt=instant + 86400, reviewedByEmail="owner@example.invalid"))
    set_json(by["job"], "serviceReportReadingsJSON", {"refrigerant_type": "R-410A", "superheat": "12"})
    set_json(by["job"], "serviceActionChecklistJSON", {"clean_coil": "completed", "replace_filter": "needs_service"})
    set_json(by["job"], "additionalTechnicianIDsJSON", [])
    set_json(by["agreement"], "coveredEquipmentIDsJSON", [by["equipment"]["id"].upper()])
    set_json(by["agreement"], "lifecycleJSON", dict(schemaVersion=2, status="active", billingInterval="monthly", autoRenews=True,
        createdAt=instant, createdByEmail="owner@example.invalid", agreementPrice=240, memberDiscountPercent=10,
        termsSummary="Two included visits", sourceServiceCallID=by["job"]["id"].upper(),
        billingEvents=[dict(id="B2000000-0000-4000-8000-000000000001", cycleDueDate=instant, amount=20,
                            invoiceID=by["invoice"]["id"].upper(), generatedAt=instant, generatedByEmail="owner@example.invalid")]))
    claim = dict(id="B2000000-0000-4000-8000-000000000002", status="approved", manufacturer="Original manufacturer",
        equipmentSerialNumberSnapshot="ORIGINAL-123", issueDescription="Leaking valve", failedPartName="Valve", quantity=1,
        originatingServiceCallID=by["job"]["id"].upper(), evidenceAttachmentIDs=[by["attachment"]["id"].upper()],
        requestedAt=instant, requestedByEmail=fixtures.EMAIL, updatedAt=instant, resolution="vendorCredit",
        expectedPartCreditCents=12345, actualPartCreditCents=12345, quickBooksVendorCreditID="PRIVATE-CREDIT",
        vendorCreditReference="PRIVATE-VENDOR-REF", originalPurchaseOrderID=by["purchaseOrder"]["id"].upper(),
        events=[dict(id="B2000000-0000-4000-8000-000000000003", kind="creditReceived", occurredAt=instant,
                     actorEmail="owner@example.invalid", detail="PRIVATE-CREDIT-AMOUNT-12345")])
    set_json(by["equipment"], "technicalBaselineReadingsJSON", dict(version=1, technicalBaselines={"refrigerant_type": "R-410A"}, warrantyClaims=[claim]))
    set_json(row(records, "item"), "flatRateAssemblyJSON", dict(schemaVersion=1, revision=2, presentation="flat_rate",
        components=[dict(itemID=records[-1]["id"].upper(), quantity=2)]))
    questions = [dict(id="B3000000-0000-4000-8000-000000000001", label="Safety checked?", kind="toggle", required=True, choices=[]),
                 dict(id="B3000000-0000-4000-8000-000000000002", label="Condition", kind="choice", required=False, choices=["Good", "Needs service"])]
    set_json(by["formTemplate"], "questionsJSON", questions)
    set_json(by["formTemplate"], "applicableServiceTypesJSON", dict(version=1, requiredForCloseout=True, serviceTypes=[contract.SPECS["job"]["type"]["enumeration"][0]]))
    answers = [dict(questionID=q["id"], label=q["label"], kind=q["kind"], required=q["required"], answer=a) for q, a in zip(questions, ["true", "Good"])]
    set_json(by["formResponse"], "answersJSON", dict(version=2, questions=questions, rows=answers))
    set_json(by["communication"], "attachmentFileNamesJSON", ["Service report.pdf"])
    set_json(by["communication"], "consentSnapshotJSON", dict(allowsTransactionalEmail=True, allowsServiceText=False,
        allowsMarketing=False, preferredContactMethod="email", consentUpdatedAt=instant))
    set_json(by["vehicleEvent"], "inspectionResultsJSON", [dict(item="tires_wheels", passed=True), dict(item="brakes_steering", passed=False)])
    set_json(by["timeEntry"], "reviewAuditJSON", dict(version=1, activityRawValue="job",
        events=[dict(id="B4000000-0000-4000-8000-000000000001", action="submitted", actorEmail=fixtures.EMAIL,
                     occurredAt=instant, detail="Submitted time", periodStart=instant - 86400, periodEnd=instant,
                     snapshotDigest="a" * 64)]))
    return records


def prepare(records, role="Field Technician", email=fixtures.EMAIL, **changes):
    graph = selection.Graph(records)
    metadata = billing_fixtures.metadata(role) | changes
    return projection.prepare(graph, graph.index(role, email), metadata, email)


def body(result, kind):
    record = next(r for r in result["records"] if r["kind"] == kind)
    return record["body"]["operational"]["_0"]


def evidence(result, kind, name):
    return body(result, kind)["structuredFields"][name]["recorded"]["_0"]


class StaffWorkspaceProjectionTests(unittest.TestCase):
    def test_every_nonbilling_field_has_exactly_one_closed_policy_and_billing_is_separate(self):
        policies = policy.policies()
        self.assertEqual(len(policies), 30)
        self.assertEqual(sum(map(len, policies.values())), 503)
        for kind, fields in policies.items():
            self.assertEqual(set(fields), set(contract.SPECS[kind]))
        with mock.patch.object(contract, "SCHEMA_DIGEST", "0" * 64):
            with self.assertRaises(selection.sharing.AttemptError): policy.policies()

    def test_all32_kinds_produce_complete_explicit_record_bodies_without_raw_operational_json(self):
        records = rich_records()
        result = prepare(records, "Admin")
        self.assertEqual(result["schema"], projection.SCHEMA)
        self.assertEqual(set(result["coverage"]), set(contract.SPECS))
        self.assertEqual(len(result["records"]), len(records))
        for entry in result["records"]:
            if entry["kind"] in ("invoice", "estimate"):
                self.assertEqual(set(entry["body"]), {"billing"})
                continue
            content = entry["body"]["operational"]["_0"]
            groups = [set(content[k]) for k in ("fields", "unavailableFields", "structuredFields")]
            self.assertEqual(set.union(*groups), set(contract.SPECS[entry["kind"]]))
            self.assertEqual(sum(map(len, groups)), len(set.union(*groups)))
            self.assertFalse(any(name.endswith("JSON") for name in content["fields"]))
            original = next(r for r in records if r["kind"] == entry["kind"] and r["id"] == entry["id"])
            for name, value in content["fields"].items(): self.assertEqual(value, original["fields"][name])

    def test_all_five_roles_match_exact_record_selection_and_do_not_inherit_local_user_role(self):
        records = rich_records(); set_value(row(records, "user"), "roleRawValue", "Admin")
        for role in selection.sharing.POLICIES:
            actual = prepare(records, role)
            expected = selection.Graph(records).index(role, fixtures.EMAIL)
            self.assertEqual([{k: v for k, v in r.items() if k != "body"} for r in actual["records"]], expected)
        self.assertEqual({r["kind"] for r in prepare(records, "Standard")["records"]}, {"user", "timeEntry", "task", "taskEvent"})

    def test_forged_index_policy_and_foreign_content_scope_cannot_be_prepared(self):
        records = rich_records(); graph = selection.Graph(records)
        index = graph.index("Admin", fixtures.EMAIL)
        with self.assertRaises(selection.sharing.AttemptError):
            projection.prepare(graph, index, billing_fixtures.metadata(), fixtures.EMAIL)
        for change in (dict(companyID=str(uuid.uuid4())), dict(replicaID=str(uuid.uuid4())), dict(environment="production"),
                       dict(sourceSequence=True), dict(projectionPolicy=selection.sharing.POLICIES["Admin"])):
            with self.assertRaises(selection.sharing.AttemptError): prepare(records, **change)

    def test_private_costs_provider_payloads_and_office_review_notes_are_not_field_data(self):
        records = rich_records()
        set_value(row(records, "technician"), "laborCostPerHour", 123.45)
        set_value(row(records, "timeOff"), "privateReviewNote", "PRIVATE-OFFICE-NOTE")
        set_value(row(records, "item"), "quickBooksCatalogReceiptJSON", '{"privateSecret":"never send"}')
        result = prepare(records)
        self.assertEqual(body(result, "technician")["unavailableFields"]["laborCostPerHour"], "roleRestricted")
        self.assertEqual(body(result, "timeOff")["unavailableFields"]["privateReviewNote"], "roleRestricted")
        self.assertEqual(body(result, "item")["unavailableFields"]["quickBooksCatalogReceiptJSON"], "serviceOnly")
        for value in ("PRIVATE-OFFICE-NOTE", "never send", "PRIVATE-CREDIT", "PRIVATE-VENDOR-REF", "PRIVATE-CREDIT-AMOUNT"):
            self.assertNotIn(value, json.dumps(result))
        self.assertEqual(body(prepare(records, "Accounting"), "technician")["fields"]["laborCostPerHour"], {"number": {"_0": 123.45}})

    def test_private_warranty_credit_value_or_presence_does_not_change_field_content(self):
        records = rich_records(); original = contract.canonical(prepare(records))
        for amount in (None, 0, 1, 99999):
            value = json.loads(selection.Graph(records).value("equipment", row(records, "equipment")["id"], "technicalBaselineReadingsJSON"))
            for field in structured.CREDIT_FIELDS.split(): value["warrantyClaims"][0][field] = amount
            set_json(row(records, "equipment"), "technicalBaselineReadingsJSON", value)
            self.assertEqual(contract.canonical(prepare(records)), original)

    def test_equipment_baselines_and_visible_claims_keep_operational_evidence_without_ledger_fields(self):
        result = prepare(rich_records())
        value = evidence(result, "equipment", "technicalBaselineReadingsJSON")
        self.assertEqual(value["technicalBaselines"], {"recorded": {"_0": {"refrigerant_type": "R-410A"}}})
        self.assertEqual(len(value["visibleWarrantyClaims"]), 1)
        claim = value["visibleWarrantyClaims"][0]
        self.assertEqual((claim["failedPartName"], claim["equipmentSerialNumberSnapshot"]), ("Valve", "ORIGINAL-123"))
        self.assertTrue(all(v == {"restricted": {}} for v in claim["financialFields"].values()))
        accounting = evidence(prepare(rich_records(), "Accounting"), "equipment", "technicalBaselineReadingsJSON")
        self.assertEqual(accounting["technicalBaselines"], {"restricted": {}})
        self.assertEqual(accounting["warrantyClaims"]["recorded"]["_0"][0]["financialFields"]["actualPartCreditCents"], {"recorded": {"_0": 12345}})

    def test_agreement_billing_ledger_is_restricted_while_terms_and_price_remain_usable(self):
        records = rich_records()
        value = evidence(prepare(records), "agreement", "lifecycleJSON")
        self.assertEqual(value["billingEvents"], {"restricted": {}})
        self.assertEqual((value["agreementPrice"], value["memberDiscountPercent"], value["termsSummary"]), (240, 10, "Two included visits"))
        accounting = evidence(prepare(records, "Accounting"), "agreement", "lifecycleJSON")
        self.assertEqual(accounting["billingEvents"]["recorded"]["_0"][0]["amount"], 20)

    def test_own_expense_and_time_remain_readable_without_granting_accounting_or_private_scheduling(self):
        records = rich_records()
        value = prepare(records)
        self.assertIn("amount", body(value, "expense")["fields"])
        self.assertIn("auditJSON", body(value, "expense")["structuredFields"])
        self.assertEqual(evidence(value, "timeEntry", "reviewAuditJSON")["activityRawValue"], "job")
        accounting = prepare(records, "Accounting")
        self.assertEqual(body(accounting, "location")["unavailableFields"]["accessNotes"], "roleRestricted")
        self.assertEqual(body(accounting, "job")["unavailableFields"]["findingsSummary"], "roleRestricted")

    def test_forms_preserve_historical_questions_answers_and_assignment_without_completing_work(self):
        value = prepare(rich_records())
        response = evidence(value, "formResponse", "answersJSON")
        self.assertEqual([r["answer"] for r in response["rows"]], ["true", "Good"])
        self.assertEqual(response["questions"], evidence(value, "formTemplate", "questionsJSON"))
        self.assertTrue(evidence(value, "formTemplate", "applicableServiceTypesJSON")["requiredForCloseout"])

    def test_bad_hidden_structured_evidence_fails_before_role_filtering(self):
        for kind, field, value in (("job", "serviceReportReadingsJSON", {"pressure": True}),
                                   ("job", "serviceActionChecklistJSON", {"check": "unknown"}),
                                   ("agreement", "lifecycleJSON", {"schemaVersion": 99}),
                                   ("technician", "supportedEquipmentTypesJSON", ["unknown equipment"]),
                                   ("communication", "consentSnapshotJSON", {"allowsMarketing": 1}),
                                   ("expense", "auditJSON", [{"rawProviderSecret": "blocked"}])):
            records = rich_records(); set_json(row(records, kind), field, value)
            with self.subTest(kind=kind), self.assertRaises(selection.sharing.AttemptError) as error:
                prepare(records, "Standard")
            self.assertEqual(error.exception.code, "operational_evidence_pending")

    def test_invalid_form_choice_response_duplicate_ids_and_diacritic_equivalent_choices_fail(self):
        records = rich_records()
        value = json.loads(selection.Graph(records).value("formResponse", row(records, "formResponse")["id"], "answersJSON"))
        value["rows"][1]["answer"] = "Not an original choice"
        set_json(row(records, "formResponse"), "answersJSON", value)
        with self.assertRaises(selection.sharing.AttemptError): prepare(records)
        for choices in (["Good", " good "], ["Café", "Cafe"]):
            records = rich_records()
            questions = json.loads(selection.Graph(records).value("formTemplate", row(records, "formTemplate")["id"], "questionsJSON"))
            questions[1]["choices"] = choices
            set_json(row(records, "formTemplate"), "questionsJSON", questions)
            with self.assertRaises(selection.sharing.AttemptError): prepare(records)

    def test_missing_nested_model_references_and_foreign_customer_lineage_fail_even_if_hidden(self):
        for kind, field, change in (("agreement", "lifecycleJSON", lambda x: x["billingEvents"][0].update(invoiceID=str(uuid.uuid4()))),
                                     ("equipment", "technicalBaselineReadingsJSON", lambda x: x["warrantyClaims"][0].update(evidenceAttachmentIDs=[str(uuid.uuid4())])),
                                     ("item", "flatRateAssemblyJSON", lambda x: x["components"][0].update(itemID=str(uuid.uuid4())))):
            records = rich_records(); record = row(records, kind)
            value = json.loads(selection.Graph(records).value(kind, record["id"], field)); change(value); set_json(record, field, value)
            with self.assertRaises(selection.sharing.AttemptError): prepare(records, "Standard")

    def test_legacy_field_forms_readings_qualifications_and_time_history_remain_representable(self):
        records = rich_records()
        set_json(row(records, "equipment"), "technicalBaselineReadingsJSON", {"refrigerant_type": "R-22"})
        set_json(row(records, "technician"), "supportedEquipmentTypesJSON", ["split_system_ac"])
        set_json(row(records, "timeEntry"), "reviewAuditJSON", [])
        set_json(row(records, "formResponse"), "answersJSON", ["B3000000-0000-4000-8000-000000000001", "false"])
        result = prepare(records)
        self.assertEqual(evidence(result, "equipment", "technicalBaselineReadingsJSON")["technicalBaselines"], {"recorded": {"_0": {"refrigerant_type": "R-22"}}})
        self.assertEqual(evidence(result, "formResponse", "answersJSON")["format"], "legacy")
        self.assertEqual(evidence(result, "timeEntry", "reviewAuditJSON")["events"], [])

    def test_all48_native_discriminator_fields_reject_unknown_values_even_for_hidden_records(self):
        original = rich_records()
        rules = discriminators.rules()
        self.assertEqual(sum(map(len, rules.values())), 48)
        native = Path(__file__).resolve().parents[1] / "GunnAire OpsTests" / "StaffWorkspaceDiscriminatorsInterop.json"
        self.assertEqual(json.loads(native.read_text()), discriminators.MANIFEST)
        for kind, fields in rules.items():
            for field, rule in fields.items():
                records = copy.deepcopy(original)
                invalid = 99 if rule["kind"] == "integer" else "unsupported-state"
                set_value(row(records, kind), field, invalid)
                with self.subTest(kind=kind, field=field), self.assertRaises(selection.sharing.AttemptError):
                    prepare(records, "Standard")

    def test_receipt_reference_colons_and_empty_discriminator_sets_keep_native_meaning(self):
        rule = discriminators.rules()["attachment"]["quickBooksAttachedEntityKeysRaw"]
        valid = rule["values"][0] + ":ORIGINAL:REFERENCE"
        self.assertTrue(discriminators.accepts(rule, valid))
        self.assertTrue(discriminators.accepts(rule, ""))
        for invalid in (valid + "\n" + valid, valid + "\n", "Invoice:123", "invoice:../wrong"):
            self.assertFalse(discriminators.accepts(rule, invalid))
        weekday = discriminators.rules()["shift"]["weekdayRawValue"]
        self.assertTrue(discriminators.accepts(weekday, 1))
        self.assertFalse(discriminators.accepts(weekday, True))

    def test_accounting_cannot_detect_baseline_presence_and_field_cannot_detect_private_claim_presence(self):
        records = rich_records(); equipment = row(records, "equipment")
        saved = json.loads(selection.Graph(records).value("equipment", equipment["id"], "technicalBaselineReadingsJSON"))
        set_value(equipment, "technicalBaselineReadingsJSON", None)
        original_accounting = contract.canonical(prepare(records, "Accounting"))
        original_field = contract.canonical(prepare(records))
        set_json(equipment, "technicalBaselineReadingsJSON", {"private_baseline": "not accounting data"})
        self.assertEqual(contract.canonical(prepare(records, "Accounting")), original_accounting)
        claim = saved["warrantyClaims"][0]
        claim.pop("originatingServiceCallID"); claim["requestedByEmail"] = "another.tech@example.invalid"
        set_json(equipment, "technicalBaselineReadingsJSON", dict(version=1, warrantyClaims=[claim]))
        self.assertEqual(contract.canonical(prepare(records)), original_field)

    def test_stale_local_user_role_and_activation_are_never_staff_authority_or_display_values(self):
        records = rich_records()
        original = contract.canonical(prepare(records))
        set_value(row(records, "user"), "roleRawValue", "Admin")
        set_value(row(records, "user"), "isActive", False)
        self.assertEqual(contract.canonical(prepare(records)), original)
        fields = body(prepare(records), "user")
        self.assertEqual(fields["unavailableFields"]["roleRawValue"], "serviceOnly")
        self.assertEqual(fields["unavailableFields"]["isActive"], "serviceOnly")

    def test_mutually_recursive_assembly_definitions_are_not_published_as_safe_catalog_content(self):
        records = rich_records()
        root = row(records, "item"); part = records[-1]
        set_json(part, "flatRateAssemblyJSON", dict(schemaVersion=1, revision=1, presentation="flat_rate",
            components=[dict(itemID=root["id"].upper(), quantity=1)]))
        with self.assertRaises(selection.sharing.AttemptError): prepare(records)

    def test_renewal_parent_cycles_fail_without_confusing_valid_reciprocal_renewal_links(self):
        records = rich_records(); original = row(records, "agreement")
        second = fixtures.clone(original); records.append(second)
        lifecycle = json.loads(selection.Graph(records).value("agreement", original["id"], "lifecycleJSON"))
        original_lifecycle = copy.deepcopy(lifecycle); original_lifecycle["pendingRenewalContractID"] = second["id"].upper()
        second_lifecycle = copy.deepcopy(lifecycle); second_lifecycle["renewalOfContractID"] = original["id"].upper()
        set_json(original, "lifecycleJSON", original_lifecycle); set_json(second, "lifecycleJSON", second_lifecycle)
        self.assertEqual(len([r for r in prepare(records, "Admin")["records"] if r["kind"] == "agreement"]), 2)
        original_lifecycle["renewalOfContractID"] = second["id"].upper()
        set_json(original, "lifecycleJSON", original_lifecycle)
        with self.assertRaises(selection.sharing.AttemptError): prepare(records)


if __name__ == "__main__":
    unittest.main()
