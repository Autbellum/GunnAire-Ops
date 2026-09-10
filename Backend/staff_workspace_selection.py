"""Closed full-owner record selection, before field disclosure or CloudKit export.

Selected identity is NOT permission to copy the record's raw fields. In
particular, financial/HR/provider fields still require role-specific adapters.
This module never returns source values, imports a model, or activates a lease.
"""
from __future__ import annotations

import uuid

try:
    from Backend import staff_workspace_contract as contract, cloudkit_staff_shares as sharing, qbo_change_capture
except ModuleNotFoundError:
    import staff_workspace_contract as contract
    import cloudkit_staff_shares as sharing
    import qbo_change_capture


VERSION = "staff-workspace-selection-v1"
OWNER_DIGEST = "d713a48445601f87bff3a47f101bd2173793fdc0d405f3a547851df5a9e4c6d3"
# target[,lineage...] for every scalar model reference. Native operation IDs
# and grouping IDs are separately classified, never interpreted as data grants.
SCALAR = {
    "customer": "", "location": "", "technician": "", "item": "", "user": "", "vendor": "", "agreement": "", "timeEntry": "", "formTemplate": "",
    "equipment": "serviceLocationID:location,customer",
    "job": "serviceLocationID:location,customer customerEquipmentID:equipment,customer maintenanceAgreementID:agreement,customer originatingServiceCallID:job,customer scheduledFollowUpServiceCallID:job,customer linkedEstimateID:estimate,customer linkedInvoiceID:invoice,customer",
    "invoice": "serviceCallID:job,customer serviceLocationID:location,customer projectMilestoneID:milestone,customer",
    "estimate": "serviceCallID:job,customer serviceLocationID:location,customer scheduledServiceCallID:job,customer parentEstimateID:estimate,customer",
    "payment": "refundedPaymentID:payment,customer,invoice",
    "availability": "technicianID:technician,technician sourceTimeOffRequestID:timeOff,technician",
    "shift": "technicianID:technician,technician",
    "timeOff": "technicianID:technician,technician approvedAvailabilityBlockID:availability,technician",
    "availabilityEvent": "requestID:timeOff,technician availabilityBlockID:availability,technician technicianID:technician,technician",
    "attachment": "serviceCallID:job,customer customerEquipmentID:equipment,customer invoiceID:invoice,customer estimateID:estimate,customer maintenanceContractID:agreement,customer fleetVehicleID:vehicle,vehicle fleetVehicleEventID:vehicleEvent,vehicle expenseClaimID:expense,customer",
    "communication": "serviceCallID:job,customer invoiceID:invoice,customer estimateID:estimate,customer maintenanceContractID:agreement,customer",
    "purchaseOrder": "serviceCallID:job,customer",
    "movement": "itemID:item serviceCallID:job,customer",
    "request": "convertedCustomerID:customer,customer convertedServiceCallID:job,customer",
    "activity": "serviceCallID:job,customer",
    "milestone": "projectServiceCallID:job,customer estimateID:estimate,customer scheduledVisitID:job,customer invoiceID:invoice,customer",
    "formResponse": "serviceCallID:job,customer templateID:formTemplate",
    "vehicle": "assignedTechnicianID:technician",
    "vehicleEvent": "vehicleID:vehicle,vehicle assignmentTechnicianID:technician",
    "expense": "serviceCallID:job,customer customerID:customer,customer receiptAttachmentID:attachment,customer",
    "alert": "customerID:customer,customer serviceLocationID:location,customer",
    "task": "customerID:customer,customer serviceLocationID:location,customer serviceCallID:job,customer estimateID:estimate,customer",
    "taskEvent": "taskID:task,customer",
}
EVIDENCE = {
    "payment": "collectionAttemptID", "availability": "creationOperationID cancellationOperationID",
    "shift": "creationOperationID retirementOperationID", "timeOff": "creationOperationID reviewOperationID withdrawalOperationID cancellationOperationID",
    "availabilityEvent": "operationID", "alert": "creationOperationID resolutionOperationID",
    "task": "creationOperationID completionOperationID cancellationOperationID", "taskEvent": "operationID",
}
GROUPS = {"estimate": {"proposalGroupID": "customer"}}
LISTS = {"job": {"additionalTechnicianIDsJSON": ("technician", ())},
         "agreement": {"coveredEquipmentIDsJSON": ("equipment", ("customer",))}}
OWNING_SCOPES = {"customer": ("customer",), "assignedTechnician": (), "invoice": ("customer", "invoice"), "serviceCall": ("customer",)}
CYCLES = {"job": ("originatingServiceCallID", "scheduledFollowUpServiceCallID"), "estimate": ("parentEstimateID",), "payment": ("refundedPaymentID",)}
DISPATCH = set("customer location equipment technician item job estimate user availability shift timeOff availabilityEvent agreement request activity milestone alert task formTemplate formResponse vendor vehicle vehicleEvent".split())
ACCOUNTING = set("customer location equipment technician item job invoice payment timeEntry agreement milestone vendor purchaseOrder movement vehicle vehicleEvent expense".split())
ATTACHMENT_KINDS = set("service_report before_photo after_photo diagnostic_photo customer_profile_photo equipment_data_plate_photo warranty_evidence customer_document maintenance_agreement invoice_support estimate_support receipt expense_receipt fleet_service other".split())


def failure(code="relationships_pending"):
    return sharing.fail(code, "The complete original workspace needs review before preparing staff data. Saved records were retained.")


def normalized(value):
    return value.strip().lower() if type(value) is str else ""


def rules():
    if contract.SCHEMA_DIGEST != OWNER_DIGEST or set(SCALAR) != set(contract.SPECS):
        raise failure("schema_changed")
    result = {}
    for kind, spec in contract.SPECS.items():
        links = {field: tuple(target.split(",")) for field, target in (entry.split(":") for entry in SCALAR[kind].split())}
        for field, descriptor in spec.items():
            if "reference" in descriptor:
                if field in links or field not in OWNING_SCOPES:
                    raise failure("schema_changed")
                links[field] = (descriptor["reference"], *OWNING_SCOPES[field])
        classified = set(links) | set(EVIDENCE.get(kind, "").split()) | set(GROUPS.get(kind, {}))
        if classified != {field for field, desc in spec.items() if desc["type"] == "identifier"}:
            raise failure("schema_changed")
        if any(target[0] not in contract.SPECS for target in links.values()):
            raise failure("schema_changed")
        result[kind] = links
    return result


class Graph:
    def __init__(self, records):
        self.links = rules()
        self.live = {kind: {} for kind in contract.SPECS}
        self.lists = {}
        seen = set()
        scope = None
        if type(records) is not list or len(records) > contract.MAX_RECORDS:
            raise failure("source_capacity")
        for record in records:
            contract.exact(record, "companyID environment replicaID schema schemaDigest kind id revision deleted fields")
            current_scope = (record["companyID"], record["environment"], record["replicaID"])
            sharing.scope(record)
            sharing.identifier(record["replicaID"])
            if record["schema"] != contract.SCHEMA_VERSION or record["schemaDigest"] != OWNER_DIGEST or scope is not None and scope != current_scope:
                raise failure("source_changed")
            scope = current_scope
            key = (record["kind"], record["id"])
            sharing.identifier(record["id"])
            contract.integer(record["revision"], 1)
            if type(record["deleted"]) is not bool or key in seen:
                raise failure("invalid_record")
            contract.validate(record["kind"], record["fields"])
            seen.add(key)
            if not record["deleted"]:
                self.live[record["kind"]][record["id"]] = record
        if sum(map(len, self.live.values())) > 20_000:
            raise failure("source_capacity")
        self.validate_links()

    def value(self, kind, key, field):
        atom = self.live[kind][key]["fields"][field]
        if atom == {"null": {}}:
            return None
        tag, content = next(iter(atom.items()))
        value = content["_0"]
        return value.lower() if tag == "identifier" else value

    def ids(self, kind, key, field):
        return self.lists[(kind, key, field)]

    def validate_links(self):
        # Union/find detects transitive customer, technician, invoice and fleet
        # conflicts, including indirect attachment -> expense -> job chains.
        parents, anchors = {}, {}
        def root(key):
            current = key
            while current in parents:
                current = parents[current]
            while key in parents:
                old = parents[key]
                parents[key] = current
                key = old
            return current
        def join(scope, left, right):
            a, b = root((scope, *left)), root((scope, *right))
            if a == b:
                return
            if a in anchors and b in anchors and anchors[a] != anchors[b]:
                raise failure("relationships_changed")
            parents[b] = a
            if b in anchors:
                anchors[a] = anchors[b]
                del anchors[b]
        for kind in ("customer", "technician", "invoice", "vehicle"):
            for key in self.live[kind]:
                anchors[(kind, kind, key)] = key
        for kind, rows in self.live.items():
            for key in rows:
                for field, (target, *scopes) in self.links[kind].items():
                    other = self.value(kind, key, field)
                    if other is None:
                        continue
                    if other not in self.live[target]:
                        raise failure()
                    for scope in scopes:
                        join(scope, (kind, key), (target, other))
                for field, scope in GROUPS.get(kind, {}).items():
                    other = self.value(kind, key, field)
                    if other is not None:
                        join(scope, (kind, key), ("group:" + kind + ":" + field, other))
                for field, (target, scopes) in LISTS.get(kind, {}).items():
                    text = self.value(kind, key, field)
                    try:
                        values = [] if text is None else qbo_change_capture.strict_json(text)
                        if type(values) is not list or len(values) > 20_000:
                            raise ValueError()
                        identifiers = []
                        for value in values:
                            if type(value) is not str or str(uuid.UUID(value)).upper() != value:
                                raise ValueError()
                            identifiers.append(value.lower())
                        if len(set(identifiers)) != len(identifiers):
                            raise ValueError()
                    except (ValueError, TypeError):
                        raise failure("invalid_record") from None
                    self.lists[(kind, key, field)] = set(identifiers)
                    for other in identifiers:
                        if other not in self.live[target]:
                            raise failure()
                        for scope in scopes:
                            join(scope, (kind, key), (target, other))
                if kind == "job":
                    if self.value(kind, key, "assignedTechnician") in self.ids(kind, key, "additionalTechnicianIDsJSON"):
                        raise failure("relationships_changed")
                    equipment = self.value(kind, key, "customerEquipmentID")
                    location = self.value(kind, key, "serviceLocationID")
                    if equipment and location and self.value("equipment", equipment, "serviceLocationID") not in (None, location):
                        raise failure("relationships_changed")
                if kind == "attachment" and self.value(kind, key, "kindRaw") not in ATTACHMENT_KINDS:
                    raise failure("unclassified_attachment")
                if kind == "item" and self.value(kind, key, "pricebookReviewStatusRawValue") not in ("approved", "needs_review", "archived"):
                    raise failure("invalid_record")
        for kind, fields in CYCLES.items():
            for field in fields:
                completed = set()
                for start in self.live[kind]:
                    path, current = set(), start
                    while current is not None and current not in completed:
                        if current in path:
                            raise failure("relationships_changed")
                        path.add(current)
                        current = self.value(kind, current, field)
                    completed.update(path)

    def selected(self, role, email):
        if role not in sharing.POLICIES or not email or normalized(email) != email:
            raise failure("access_required")
        selected = {kind: set() for kind in self.live}
        if role == "Admin":
            return {kind: set(rows) for kind, rows in self.live.items()}
        for kind in DISPATCH if role == "Dispatcher" else ACCOUNTING if role == "Accounting" else ():
            selected[kind] = set(self.live[kind])
        def own(kind, field):
            return {key for key in self.live[kind] if normalized(self.value(kind, key, field)) == email}
        if role != "Dispatcher":
            selected["user"] = own("user", "email")
        if role != "Accounting":
            selected["timeEntry"] = own("timeEntry", "userEmail")
            selected["expense"] = own("expense", "claimantEmail") if role != "Standard" else set()
        if role != "Dispatcher":
            selected["task"] = own("task", "assignedToEmail")
        selected["taskEvent"] = {key for key in self.live["taskEvent"] if self.value("taskEvent", key, "taskID") in selected["task"]}
        if role == "Field Technician":
            technician = own("technician", "contactInfo")
            if len(technician) != 1:
                raise failure("identity_pending" if not technician else "identity_ambiguous")
            selected["technician"] = set(technician)
            jobs = {key for key in self.live["job"] if self.value("job", key, "assignedTechnician") in technician or
                    self.ids("job", key, "additionalTechnicianIDsJSON") & technician}
            selected["job"] = jobs
            selected["customer"] = {self.value("job", key, "customer") for key in jobs}
            for key in jobs:
                selected["technician"].update(self.ids("job", key, "additionalTechnicianIDsJSON"))
                for field, target in (("assignedTechnician", "technician"), ("serviceLocationID", "location"), ("customerEquipmentID", "equipment")):
                    value = self.value("job", key, field)
                    if value:
                        selected[target].add(value)
            selected["location"].update(self.value("equipment", key, "serviceLocationID") for key in selected["equipment"]
                                        if self.value("equipment", key, "serviceLocationID"))
            selected["equipment"].update(key for key in self.live["equipment"] if
                self.value("equipment", key, "customer") in selected["customer"] and
                self.value("equipment", key, "serviceLocationID") in selected["location"])
            selected["invoice"] = {key for key in self.live["invoice"] if self.value("invoice", key, "serviceCallID") in jobs}
            selected["payment"] = {key for key in self.live["payment"] if self.value("payment", key, "invoice") in selected["invoice"]}
            selected["item"] = {key for key in self.live["item"] if self.value("item", key, "pricebookReviewStatusRawValue") in ("approved", "archived") or
                                normalized(self.value("item", key, "pricebookCreatedByEmail")) == email}
            for kind in ("availability", "shift", "timeOff", "availabilityEvent"):
                selected[kind] = {key for key in self.live[kind] if self.value(kind, key, "technicianID") in technician}
            selected["timeOff"] &= own("timeOff", "requestedByEmail")
            selected["activity"] = {key for key in self.live["activity"] if self.value("activity", key, "serviceCallID") in jobs}
            selected["milestone"] = {key for key in self.live["milestone"] if self.value("milestone", key, "projectServiceCallID") in jobs or
                                      self.value("milestone", key, "scheduledVisitID") in jobs}
            selected["formResponse"] = {key for key in self.live["formResponse"] if self.value("formResponse", key, "serviceCallID") in jobs}
            selected["formTemplate"] = {key for key in self.live["formTemplate"] if self.value("formTemplate", key, "isActive")}
            selected["formTemplate"].update(self.value("formResponse", key, "templateID") for key in selected["formResponse"])
            selected["agreement"] = {key for key in self.live["agreement"] if self.value("agreement", key, "customer") in selected["customer"] and
                (not self.ids("agreement", key, "coveredEquipmentIDsJSON") or self.ids("agreement", key, "coveredEquipmentIDsJSON") & selected["equipment"])}
            selected["agreement"].update(self.value("job", key, "maintenanceAgreementID") for key in jobs if self.value("job", key, "maintenanceAgreementID"))
            selected["alert"] = {key for key in self.live["alert"] if self.value("alert", key, "customerID") in selected["customer"] and
                                  self.value("alert", key, "serviceLocationID") in selected["location"] | {None}}
            selected["vehicle"] = {key for key in self.live["vehicle"] if self.value("vehicle", key, "assignedTechnicianID") in technician}
            selected["vehicleEvent"] = {key for key in self.live["vehicleEvent"] if self.value("vehicleEvent", key, "vehicleID") in selected["vehicle"]}
            selected["vendor"] = set(self.live["vendor"])
        if role in ("Field Technician", "Dispatcher"):
            jobs = selected["job"]
            selected["purchaseOrder"] = {key for key in self.live["purchaseOrder"] if self.value("purchaseOrder", key, "serviceCallID") in jobs or
                                         normalized(self.value("purchaseOrder", key, "createdByEmail")) == email}
            locations = {self.value("vehicle", key, "stockLocation") for key in selected["vehicle"]} - {None, ""}
            if role == "Field Technician":
                if any(not self.value("vehicle", key, "stockLocation") for key in selected["vehicle"]):
                    raise failure("stock_identity_pending")
                for location in locations:
                    if sum(self.value("vehicle", key, "stockLocation") == location for key in self.live["vehicle"]) != 1:
                        raise failure("stock_identity_ambiguous")
            selected["movement"] = {key for key in self.live["movement"] if self.value("movement", key, "serviceCallID") in jobs or
                                     self.value("movement", key, "sourceLocation") in locations or self.value("movement", key, "destinationLocation") in locations}
        if role != "Standard":
            for key in self.live["attachment"]:
                if self.attachment_allowed(key, selected, role):
                    selected["attachment"].add(key)
            for key in self.live["communication"]:
                if self.linked_allowed("communication", key, selected, customer_only=role in ("Dispatcher", "Accounting")):
                    selected["communication"].add(key)
        return selected

    def linked_allowed(self, kind, key, selected, *, customer_only=False):
        links = [(target[0], self.value(kind, key, field)) for field, target in self.links[kind].items() if field != "customer"]
        linked = [(target, value) for target, value in links if value is not None]
        # All explicit parents must be allowed. One allowed job must not wash
        # a private invoice/expense/fleet attachment into a broader audience.
        if linked:
            return all(value in selected[target] for target, value in linked)
        return customer_only and self.value(kind, key, "customer") in selected["customer"]

    def attachment_allowed(self, key, selected, role):
        kind = self.value("attachment", key, "kindRaw")
        if kind not in ATTACHMENT_KINDS:
            raise failure("unclassified_attachment")
        financial = role == "Accounting"
        statement = kind == "customer_document" and self.value("attachment", key, "displayName").startswith("GunnAire-Account-Statement-")
        if (kind == "receipt" or statement) and not financial:
            return False
        required = {"invoice_support": "invoiceID", "estimate_support": "estimateID", "expense_receipt": "expenseClaimID",
                    "maintenance_agreement": "maintenanceContractID"}
        if kind in required and self.value("attachment", key, required[kind]) is None:
            return False
        if kind == "fleet_service" and not (self.value("attachment", key, "fleetVehicleID") or self.value("attachment", key, "fleetVehicleEventID")):
            return False
        if kind == "expense_receipt" and self.value("attachment", key, "expenseClaimID") in selected["expense"]:
            # An employee keeps their own expense receipt after job reassignment.
            # Context links do not grant a customer/job; other private parents
            # still require their independent authorization.
            return all(self.value("attachment", key, field) is None or self.value("attachment", key, field) in selected[target[0]]
                       for field, target in self.links["attachment"].items() if field not in ("customer", "serviceCallID"))
        return self.linked_allowed("attachment", key, selected, customer_only=role in ("Dispatcher", "Accounting"))

    def index(self, role, email):
        selected = self.selected(role, email)
        result = []
        for kind in sorted(selected):
            for key in sorted(selected[kind]):
                unavailable = []
                for field, (target, *_) in self.links[kind].items():
                    value = self.value(kind, key, field)
                    if value is not None and value not in selected[target]:
                        unavailable.append(field)
                for field, (target, _) in LISTS.get(kind, {}).items():
                    if not self.ids(kind, key, field) <= selected[target]:
                        unavailable.append(field)
                result.append(dict(kind=kind, id=key, revision=self.live[kind][key]["revision"], unavailableLinks=sorted(unavailable)))
        return result
