"""Strict operational JSON adapters, separate from lossless owner archives.

No raw provider envelopes are admitted. Structured display values are not
owner-model JSON and cannot be used as approval or mutation instructions.
"""
from __future__ import annotations

import copy
import re
import unicodedata

try:
    from Backend import staff_billing_projection as atoms, staff_workspace_contract as contract
    from Backend import staff_workspace_selection as selection
    from Backend import staff_workspace_discriminators as discriminators
except ModuleNotFoundError:
    import staff_billing_projection as atoms
    import staff_workspace_contract as contract
    import staff_workspace_selection as selection
    import staff_workspace_discriminators as discriminators

JSON_FIELDS = {
    "technician": {"serviceAreasJSON", "supportedEquipmentTypesJSON"},
    "equipment": {"technicalBaselineReadingsJSON"}, "item": {"flatRateAssemblyJSON"},
    "job": {"additionalTechnicianIDsJSON", "serviceActionChecklistJSON", "serviceReportReadingsJSON"},
    "timeEntry": {"reviewAuditJSON"}, "agreement": {"coveredEquipmentIDsJSON", "lifecycleJSON"},
    "communication": {"attachmentFileNamesJSON", "consentSnapshotJSON"},
    "formTemplate": {"questionsJSON", "applicableServiceTypesJSON"}, "formResponse": {"answersJSON"},
    "vehicleEvent": {"inspectionResultsJSON"}, "expense": {"auditJSON"},
}
TYPES = {"t": atoms.text, "u": atoms.identifier, "d": atoms.date, "b": atoms.flag, "n": atoms.number,
         "i": lambda x: contract.integer(x)}
require = atoms.require


def typed(value, required, optional=""):
    specs = {name: kind for name, kind in (part.split(":") for part in (required + " " + optional).split())}
    atoms.shape(value, " ".join(part.split(":")[0] for part in required.split()), " ".join(part.split(":")[0] for part in optional.split()))
    result = copy.deepcopy(value)
    for name, kind in specs.items():
        if result.get(name) is not None:
            result[name] = TYPES[kind](result[name])
    return result


def strings(value, *, unique=False, choices=None):
    result = [atoms.text(x) for x in atoms.array(value, 20_000)]
    if unique:
        require(len(result) == len(set(result)))
    if choices is not None:
        require(set(result) <= set(choices))
    return result


def string_map(value, choices=None):
    require(type(value) is dict and len(value) <= 20_000)
    for key, val in value.items():
        atoms.text(key, True); atoms.text(val)
        require(choices is None or val in choices)
    return value


def events(value, actions, *, detail_required=True, extended=False):
    result, seen = [], set()
    for entry in atoms.array(value, 10_000):
        base = "id:u action:t actorEmail:t occurredAt:d"
        extra = "periodStart:d periodEnd:d snapshotDigest:t" if extended else ""
        current = typed(entry, base + (" detail:t" if detail_required else ""), extra + (" detail:t" if not detail_required else ""))
        require(current["id"] not in seen and current["action"] in actions)
        seen.add(current["id"])
        if current.get("snapshotDigest") is not None:
            require(re.fullmatch("[0-9a-f]{64}", current["snapshotDigest"]) is not None)
        if current.get("periodStart") is not None and current.get("periodEnd") is not None:
            require(current["periodStart"] < current["periodEnd"])
        result.append(current)
    return result


def questions(value):
    result, seen = [], set()
    for entry in atoms.array(value, 10_000):
        atoms.shape(entry, "id label kind required choices")
        current = typed({k: v for k, v in entry.items() if k != "choices"}, "id:u label:t kind:t required:b")
        require(current["id"] not in seen and current["kind"] in ("toggle", "text", "choice"))
        atoms.text(current["label"], True)
        seen.add(current["id"])
        values = strings(entry["choices"])
        if current["kind"] == "choice":
            normalized = ["".join(c for c in unicodedata.normalize("NFD", choice.strip()).casefold()
                                  if unicodedata.category(c) != "Mn") for choice in values]
            require(len(values) >= 2 and all(normalized) and len(set(normalized)) == len(values))
        else:
            require(not values)
        current["choices"] = values
        result.append(current)
    return result


def response(value, original_questions):
    if value == {} or type(value) is list:
        values = [] if value == {} else atoms.array(value, 20_000)
        require(len(values) % 2 == 0)
        answers = {}
        for index in range(0, len(values), 2):
            key = atoms.identifier(values[index])
            require(key not in answers)
            answers[key] = atoms.text(values[index + 1])
        result = dict(format="legacy", answers=answers)
    else:
        require(type(value) is dict and type(value.get("version")) is int and value["version"] in (1, 2))
        atoms.shape(value, "version rows" + (" questions" if value["version"] == 2 else ""))
        rows = [typed(r, "questionID:u label:t kind:t required:b answer:t") for r in atoms.array(value["rows"], 10_000)]
        require(len(rows) == len(original_questions))
        for row, question in zip(rows, original_questions):
            require(row["questionID"] == question["id"] and all(row[name] == question[name] for name in ("label", "kind", "required")))
        if value["version"] == 2:
            require(questions(value["questions"]) == original_questions)
        answers = {row["questionID"]: row["answer"] for row in rows}
        require(len(answers) == len(rows))
        result = dict(format="snapshot", version=value["version"], rows=rows)
        if value["version"] == 2:
            result["questions"] = original_questions
    require(set(answers) <= {q["id"] for q in original_questions})
    for question in original_questions:
        answer = answers.get(question["id"], "")
        if question["kind"] == "toggle":
            require(answer in ("", "true", "false"))
        elif question["kind"] == "choice":
            require(not answer or answer in question["choices"])
    return result


class Structured:
    def __init__(self, graph):
        self.graph = graph
        self.values = {}

    def value(self, record, field):
        return self.graph.value(record["kind"], record["id"], field)

    def customer(self, kind, identity):
        if kind == "customer":
            return identity
        record = self.graph.live[kind][identity]
        for field in ("customer", "customerID"):
            if field in record["fields"]:
                return self.value(record, field)
        for field in ("serviceCallID", "projectServiceCallID"):
            if field in record["fields"]:
                job = self.value(record, field)
                return self.graph.value("job", job, "customer") if job else None
        return None

    def link(self, record, kind, value, *, same_customer=False):
        identity = atoms.identifier(value)
        require(identity.lower() in self.graph.live[kind])
        if same_customer:
            target = self.customer(kind, identity.lower())
            require(target is None or target == self.customer(record["kind"], record["id"]))
        return identity

    def identifiers(self, record, kind, value, *, same_customer=False):
        values = [self.link(record, kind, x, same_customer=same_customer) for x in atoms.array(value, 20_000)]
        require(len(values) == len(set(values)))
        return values

    def validate(self):
        # Validate full original structured evidence before role filtering.
        try:
            for kind, fields in JSON_FIELDS.items():
                for identity, record in self.graph.live[kind].items():
                    for field in fields:
                        raw = self.value(record, field)
                        if raw is None:
                            self.values[(kind, identity, field)] = None
                        else:
                            self.values[(kind, identity, field)] = self.read(record, field, atoms.parse(raw))
            self.cycles("item", {
                identity: [c["itemID"].lower() for c in self.values.get(("item", identity, "flatRateAssemblyJSON"), {}).get("components", [])]
                if self.values.get(("item", identity, "flatRateAssemblyJSON")) is not None else [] for identity in self.graph.live["item"]})
            for field in ("renewalOfContractID", "pendingRenewalContractID", "supersededByContractID"):
                edges = {}
                for identity in self.graph.live["agreement"]:
                    value = self.values.get(("agreement", identity, "lifecycleJSON")) or {}
                    edges[identity] = [value[field].lower()] if value.get(field) is not None else []
                self.cycles("agreement", edges)
            return self
        except selection.sharing.AttemptError:
            raise selection.failure("operational_evidence_pending") from None

    def cycles(self, kind, edges):
        # Iterative topological traversal; long histories cannot overflow the
        # call stack and are never shortened to make a graph appear valid.
        counts = {identity: 0 for identity in self.graph.live[kind]}
        for children in edges.values():
            for child in children:
                counts[child] += 1
        ready = [identity for identity, count in counts.items() if count == 0]
        visited = 0
        while ready:
            identity = ready.pop(); visited += 1
            for child in edges.get(identity, []):
                counts[child] -= 1
                if counts[child] == 0:
                    ready.append(child)
        require(visited == len(counts))

    def read(self, record, field, value):
        kind = record["kind"]
        if field == "additionalTechnicianIDsJSON":
            return self.identifiers(record, "technician", value)
        if field == "coveredEquipmentIDsJSON":
            return self.identifiers(record, "equipment", value, same_customer=True)
        if field in ("serviceAreasJSON", "attachmentFileNamesJSON"):
            return strings(value)
        if field == "serviceReportReadingsJSON":
            return string_map(value)
        if field == "serviceActionChecklistJSON":
            return string_map(value, {"not_checked", "completed", "monitor", "needs_service", "not_applicable"})
        if field == "supportedEquipmentTypesJSON":
            choices = discriminators.MANIFEST["rules"]["equipment"]["equipmentTypeRaw"]["values"]
            if type(value) is list:
                return dict(format="legacy", supportedEquipmentTypeRawValues=strings(value, unique=True, choices=choices))
            atoms.shape(value, "version supportedEquipmentTypeRawValues", "reviewedAt reviewDueAt reviewedByEmail")
            require(type(value["version"]) is int and value["version"] == 2)
            result = typed({k: v for k, v in value.items() if k != "supportedEquipmentTypeRawValues"}, "version:i", "reviewedAt:d reviewDueAt:d reviewedByEmail:t")
            result["supportedEquipmentTypeRawValues"] = strings(value["supportedEquipmentTypeRawValues"], unique=True, choices=choices)
            return result
        if field == "inspectionResultsJSON":
            result, seen = [], set()
            for entry in atoms.array(value, 6):
                entry = typed(entry, "item:t passed:b")
                require(entry["item"] not in seen and entry["item"] in {"tires_wheels", "brakes_steering", "lights_signals", "fluids_leaks", "windshield_body", "safety_equipment"})
                seen.add(entry["item"]); result.append(entry)
            return result
        if field == "consentSnapshotJSON":
            result = typed(value, "allowsTransactionalEmail:b allowsServiceText:b allowsMarketing:b preferredContactMethod:t", "consentUpdatedAt:d")
            require(result["preferredContactMethod"] in discriminators.MANIFEST["rules"]["customer"]["preferredContactMethodRaw"]["values"])
            return result
        if field == "auditJSON" and kind == "expense":
            return events(value, {"submitted", "correctionRequested", "resubmitted", "approved", "rejected", "reimbursed"})
        if field == "reviewAuditJSON":
            actions = {"submitted", "correction_requested", "corrected_and_resubmitted", "approved", "employee_signed_off"}
            if type(value) is list:
                return dict(format="legacy", events=events(value, actions, detail_required=False, extended=True))
            atoms.shape(value, "version events", "activityRawValue")
            require(type(value["version"]) is int and value["version"] == 1)
            result = dict(version=1, events=events(value["events"], actions, detail_required=False, extended=True))
            if value.get("activityRawValue") is not None:
                require(value["activityRawValue"] in {"job", "travel", "supply_run", "shop_warehouse", "training", "meeting", "administrative", "paid_break", "unpaid_break", "general"})
                result["activityRawValue"] = value["activityRawValue"]
            return result
        if field == "questionsJSON":
            atoms.text(self.value(record, "title"), True)
            return questions(value)
        if field == "applicableServiceTypesJSON":
            if type(value) is list:
                return dict(format="legacy", serviceTypes=strings(value, unique=True, choices=contract.SPECS["job"]["type"]["enumeration"]))
            atoms.shape(value, "version requiredForCloseout serviceTypes")
            require(type(value["version"]) is int and value["version"] == 1)
            return dict(version=1, requiredForCloseout=atoms.flag(value["requiredForCloseout"]),
                        serviceTypes=strings(value["serviceTypes"], unique=True, choices=contract.SPECS["job"]["type"]["enumeration"]))
        if field == "answersJSON":
            template = self.graph.live["formTemplate"][self.value(record, "templateID")]
            require(self.value(template, "title") == self.value(record, "templateTitle"))
            original = questions(atoms.parse(self.value(template, "questionsJSON")))
            return response(value, original)
        if field == "flatRateAssemblyJSON":
            atoms.shape(value, "schemaVersion revision presentation components")
            require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1)
            contract.integer(value["revision"], 1)
            require(value["presentation"] in ("flat_rate", "itemized"))
            components, seen = [], set()
            for entry in atoms.array(value["components"], 750):
                entry = typed(entry, "itemID:u quantity:n")
                self.link(record, "item", entry["itemID"])
                require(entry["itemID"].lower() != record["id"] and entry["itemID"] not in seen and 0 < entry["quantity"] <= 999_999)
                seen.add(entry["itemID"]); components.append(entry)
            require(bool(components))
            return dict(value, components=components)
        if field == "lifecycleJSON":
            return self.agreement(record, value)
        if field == "technicalBaselineReadingsJSON":
            return self.equipment(record, value)
        raise selection.failure("schema_changed")

    def agreement(self, record, value):
        atoms.shape(value, "schemaVersion status billingInterval autoRenews createdAt",
            "agreementPrice billingCatalogItemID billingAnchorDate billingConfiguredAt billingConfiguredByEmail billingEvents memberDiscountPercent termsSummary createdByEmail offeredAt offeredByEmail sourceServiceCallID approvedAt approvedByName approvalMethodRaw approvalReference approvalSignatureImageBase64 approvalRecordedByEmail declinedAt declinedByName cancelledAt cancelledByEmail cancellationReason generatedDocumentAttachmentID renewalOfContractID pendingRenewalContractID renewalStartedAt renewalStartedByEmail supersededByContractID renewedAt renewedByEmail")
        result = typed({k: v for k, v in value.items() if k != "billingEvents"},
            "schemaVersion:i status:t billingInterval:t autoRenews:b createdAt:d",
            "agreementPrice:n billingCatalogItemID:u billingAnchorDate:d billingConfiguredAt:d billingConfiguredByEmail:t memberDiscountPercent:n termsSummary:t createdByEmail:t offeredAt:d offeredByEmail:t sourceServiceCallID:u approvedAt:d approvedByName:t approvalMethodRaw:t approvalReference:t approvalSignatureImageBase64:t approvalRecordedByEmail:t declinedAt:d declinedByName:t cancelledAt:d cancelledByEmail:t cancellationReason:t generatedDocumentAttachmentID:u renewalOfContractID:u pendingRenewalContractID:u renewalStartedAt:d renewalStartedByEmail:t supersededByContractID:u renewedAt:d renewedByEmail:t")
        require(result["schemaVersion"] in (1, 2) and result["status"] in {"draft", "pendingApproval", "active", "renewed", "declined", "cancelled"})
        require(result["billingInterval"] in {"perVisit", "monthly", "annual", "fullTerm"})
        require(result.get("memberDiscountPercent") is None or result["memberDiscountPercent"] <= 100)
        for field, kind in (("billingCatalogItemID", "item"), ("sourceServiceCallID", "job"), ("generatedDocumentAttachmentID", "attachment"),
                            ("renewalOfContractID", "agreement"), ("pendingRenewalContractID", "agreement"), ("supersededByContractID", "agreement")):
            if result.get(field) is not None:
                self.link(record, kind, result[field], same_customer=True)
                if kind == "agreement":
                    require(result[field].lower() != record["id"])
        if value.get("billingEvents") is not None:
            rows, seen = [], set()
            for event in atoms.array(value["billingEvents"], 10_000):
                event = typed(event, "id:u cycleDueDate:d amount:n invoiceID:u generatedAt:d generatedByEmail:t", "serviceCallID:u")
                require(event["id"] not in seen); seen.add(event["id"])
                self.link(record, "invoice", event["invoiceID"], same_customer=True)
                if event.get("serviceCallID") is not None:
                    self.link(record, "job", event["serviceCallID"], same_customer=True)
                rows.append(event)
            result["billingEvents"] = rows
        elif "billingEvents" in value:
            result["billingEvents"] = None
        return result

    def equipment(self, record, value):
        if type(value) is dict and all(type(v) is str for v in value.values()):
            return dict(format="legacy", technicalBaselines=string_map(value))
        atoms.shape(value, "", "version technicalBaselines warrantyClaims")
        result = dict(format="versioned", version=value.get("version", 1))
        require(type(result["version"]) is int and result["version"] == 1)
        if "technicalBaselines" in value:
            result["technicalBaselines"] = string_map(value["technicalBaselines"]) if value["technicalBaselines"] is not None else None
        if value.get("warrantyClaims") is not None:
            claims, seen = [], set()
            for original in atoms.array(value["warrantyClaims"], 10_000):
                atoms.shape(original, "id status manufacturer equipmentSerialNumberSnapshot issueDescription failedPartName quantity evidenceAttachmentIDs requestedAt requestedByEmail updatedAt events",
                    "distributorName failedPartNumber failedPartSerialNumber originatingServiceCallID originalPurchaseOrderID originalPurchaseOrderLineID claimNumber resolution denialReason expectedPartCreditCents expectedLaborCreditCents replacementCatalogItemID replacementPartName replacementPartNumber replacementSerialNumber replacementInventoryMovementID replacementReceivedAt actualPartCreditCents actualLaborCreditCents vendorCreditReference quickBooksVendorCreditID creditReceivedAt submittedAt submittedByEmail decidedAt decidedByEmail closedAt closedByEmail")
                excluded = {"events", "evidenceAttachmentIDs"} | set(CREDIT_FIELDS.split())
                claim = typed({k: v for k, v in original.items() if k not in excluded},
                    "id:u status:t manufacturer:t equipmentSerialNumberSnapshot:t issueDescription:t failedPartName:t quantity:n requestedAt:d requestedByEmail:t updatedAt:d",
                    "distributorName:t failedPartNumber:t failedPartSerialNumber:t originatingServiceCallID:u originalPurchaseOrderID:u originalPurchaseOrderLineID:u claimNumber:t resolution:t denialReason:t replacementCatalogItemID:u replacementPartName:t replacementPartNumber:t replacementSerialNumber:t replacementInventoryMovementID:u replacementReceivedAt:d vendorCreditReference:t quickBooksVendorCreditID:t creditReceivedAt:d submittedAt:d submittedByEmail:t decidedAt:d decidedByEmail:t closedAt:d closedByEmail:t")
                require(claim["id"] not in seen and claim["status"] in {"requested", "submitted", "approved", "denied", "closed", "cancelled"})
                seen.add(claim["id"])
                require(0 < claim["quantity"] <= 999_999)
                require(claim.get("resolution") is None or claim["resolution"] in {"replacement", "vendorCredit", "laborCredit", "replacementAndCredit"})
                for field in CREDIT_FIELDS.split():
                    if field in original:
                        amount = original[field]
                        require(amount is None or type(amount) is int and 0 <= amount <= 9_999_999_999_999)
                        claim[field] = amount
                for field, kind in CLAIM_LINKS.items():
                    if claim.get(field) is not None:
                        self.link(record, kind, claim[field], same_customer=True)
                claim["evidenceAttachmentIDs"] = self.identifiers(record, "attachment", original["evidenceAttachmentIDs"], same_customer=True)
                event_rows, event_ids = [], set()
                for event in atoms.array(original["events"], 10_000):
                    event = typed(event, "id:u kind:t occurredAt:d actorEmail:t detail:t")
                    require(event["id"] not in event_ids and event["kind"] in {"requested", "submitted", "approved", "denied", "replacementReceived", "creditReceived", "closed", "cancelled"})
                    event_ids.add(event["id"]); event_rows.append(event)
                claim["events"] = event_rows
                claims.append(claim)
            result["warrantyClaims"] = claims
        elif "warrantyClaims" in value:
            result["warrantyClaims"] = None
        return result


CREDIT_FIELDS = "expectedPartCreditCents expectedLaborCreditCents actualPartCreditCents actualLaborCreditCents"
CLAIM_LINKS = {"originatingServiceCallID": "job", "originalPurchaseOrderID": "purchaseOrder",
               "replacementCatalogItemID": "item", "replacementInventoryMovementID": "movement"}
CLAIM_PRIVATE = set((CREDIT_FIELDS + " vendorCreditReference quickBooksVendorCreditID creditReceivedAt originalPurchaseOrderID originalPurchaseOrderLineID").split())


def unavailable_links(value, links, selected):
    return sorted(field for field, kind in links.items() if value.get(field) is not None and (kind, value[field].lower()) not in selected)


def disclose(kind, field, value, role, email, selected):
    """Nested field privacy; all values have already passed original validation."""
    equipment = kind == "equipment" and field == "technicalBaselineReadingsJSON"
    if value is None and not equipment:
        return {"notRecorded": {}}
    financial = role in ("Admin", "Accounting")
    result = copy.deepcopy(value) if value is not None else {}
    if kind == "agreement" and field == "lifecycleJSON":
        # A selected agreement is not authority to read its whole invoice ledger.
        result["billingEvents"] = atoms.disclosure(result.get("billingEvents"), financial)
        result["unavailableLinks"] = unavailable_links(result, {
            "billingCatalogItemID": "item", "sourceServiceCallID": "job", "generatedDocumentAttachmentID": "attachment",
            "renewalOfContractID": "agreement", "pendingRenewalContractID": "agreement", "supersededByContractID": "agreement"}, selected)
    if equipment:
        # The output is a normalized view, not the original envelope. Its outer
        # presence/format cannot reveal baseline-only or private-claim changes.
        result = {key: result[key] for key in ("technicalBaselines", "warrantyClaims") if key in result}
        result["technicalBaselines"] = atoms.disclosure(result.get("technicalBaselines"), role != "Accounting")
        original_claims = result.get("warrantyClaims")
        if original_claims is not None:
            claims = []
            for claim in original_claims:
                job = claim.get("originatingServiceCallID")
                owned = selection.normalized(claim["requestedByEmail"]) == selection.normalized(email)
                if not financial and role != "Dispatcher" and not (owned or job is not None and ("job", job.lower()) in selected):
                    continue
                fields = {key: val for key, val in claim.items() if key not in CLAIM_PRIVATE}
                fields["financialFields"] = {key: atoms.disclosure(claim.get(key), financial) for key in sorted(CLAIM_PRIVATE)}
                fields["events"] = [{key: val for key, val in event.items() if key != "detail"} | {
                    "detail": atoms.disclosure(event["detail"], financial)} for event in claim["events"]]
                links = {key: val for key, val in CLAIM_LINKS.items() if key not in CLAIM_PRIVATE}
                fields["unavailableLinks"] = unavailable_links(fields, links, selected)
                if any(("attachment", key.lower()) not in selected for key in fields["evidenceAttachmentIDs"]):
                    fields["unavailableLinks"].append("evidenceAttachmentIDs")
                    fields["unavailableLinks"].sort()
                claims.append(fields)
            result["warrantyClaims"] = atoms.disclosure(claims, True)
        else:
            result["warrantyClaims"] = {"notRecorded": {}}
        if not financial and role != "Dispatcher":
            # This is a selection of visible claims, not an assertion that the
            # original equipment has an empty warranty history.
            result["visibleWarrantyClaims"] = result.pop("warrantyClaims").get("recorded", {}).get("_0", [])
            # Constant marker: never reveal whether private claims exist.
            result["otherClaims"] = {"restricted": {}}
    return {"recorded": {"_0": result}}
