"""Explicit core-field projection schema; not a complete business-store schema.

No raw model dumps, credentials, accounting administration, payment methods or
provider response bodies cross this boundary. Unknown fields/types fail rather
than becoming silently omitted records. Later schemas must enumerate additional
business domains before a staff operational workspace can be enabled.
"""
from __future__ import annotations

import math
import re
from datetime import datetime

try:
    from Backend import cloudkit_staff_shares as sharing
except ModuleNotFoundError:
    import cloudkit_staff_shares as sharing


SCHEMA_VERSION = "core-field-v1"
# Required fields precede |; optional fields remain explicit and nullable.
SPECS = {
    "customer": ("name:s", "phone:s email:s address:s allowsTransactionalEmail:b allowsServiceText:b preferredContactMethod:s"),
    "location": ("customerID:id name:s address:s isActive:b", "contactName:s contactPhone:s accessNotes:note isPrimary:b"),
    "equipment": ("customerID:id name:s isActive:b", "serviceLocationID:id equipmentType:s manufacturer:s modelNumber:s serialNumber:s location:s installDate:date warrantyExpiration:date filterSize:s notes:note"),
    "technician": ("name:s isActive:b", "email:email phone:s"),
    "job": ("customerID:id type:s scheduledDate:date duration:number status:s assignedTechnicianIDs:ids", "eventTitle:s siteAddress:s serviceLocationID:id customerEquipmentID:id notes:note findingsSummary:note recommendedWorkSummary:note dispatchUrgency:s promisedArrivalWindowStart:date promisedArrivalWindowEnd:date followUpRequired:b followUpAction:note followUpDueDate:date visitDisposition:s visitDispositionNotes:note originatingServiceCallID:id scheduledFollowUpServiceCallID:id cancellationReason:note cancelledAt:date technicianEnRouteAt:date technicianArrivedAt:date"),
    "item": ("name:s itemType:s unitPrice:money isTaxable:b reviewStatus:s", "description:note sku:s createdByEmail:email purchaseCost:money vendorPartNumber:s quickBooksID:s"),
}
COVERAGE = sorted(SPECS)
AUTHORITY_FIELDS = {
    "customer": (), "location": ("customerID",), "equipment": ("customerID", "serviceLocationID"),
    "technician": ("email", "isActive"),
    "job": ("customerID", "serviceLocationID", "customerEquipmentID", "assignedTechnicianIDs", "originatingServiceCallID", "scheduledFollowUpServiceCallID"),
    "item": ("reviewStatus", "createdByEmail"),
}


def authority_changed(previous, kind, action, fields):
    return previous is None or action != "upsert" or any(previous["fields"].get(key) != fields.get(key) for key in AUTHORITY_FIELDS[kind])


def invalid():
    return sharing.fail("invalid_record", "Use the supported operational fields and original record identifiers.", 400)


def field(value, kind):
    if kind == "b":
        if type(value) is not bool:
            raise invalid()
    elif kind in ("number", "money"):
        if type(value) not in (int, float) or not 0 <= value <= 1_000_000_000 or not math.isfinite(value):
            raise invalid()
    elif kind == "id":
        sharing.identifier(value)
    elif kind == "ids":
        if not isinstance(value, list) or len(value) > 100 or any(not isinstance(v, str) for v in value):
            raise invalid()
        for item in value:
            sharing.identifier(item)
        if value != sorted(set(value)):
            raise invalid()
    else:
        if (not isinstance(value, str) or any(0xD800 <= ord(c) <= 0xDFFF for c in value)
                or len(value.encode("utf-8")) > (16_384 if kind == "note" else 2048)
                or any(ord(c) < 32 and c not in "\t\n\r" for c in value) or "\x7f" in value):
            raise invalid()
        if kind == "email" and (value != value.strip().lower() or re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value) is None):
            raise invalid()
        if kind == "date":
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    raise ValueError()
            except ValueError:
                raise invalid() from None


def validate(kind, values):
    if not isinstance(kind, str) or kind not in SPECS or not isinstance(values, dict):
        raise invalid()
    required, optional = (dict(part.split(":") for part in spec.split()) for spec in SPECS[kind])
    allowed = required | optional
    if not set(required) <= set(values) <= set(allowed):
        raise invalid()
    for name, value in values.items():
        if value is None and name in optional:
            continue
        field(value, allowed[name])
    if "name" in required and not values["name"].strip():
        raise invalid()
    if kind == "item" and values["reviewStatus"] not in ("approved", "needs_review", "archived"):
        raise invalid()
    return values


def selected_records(records, member):
    """Filter before export. Full-schema snapshots represent removals by absence.

    An unresolved relationship blocks the snapshot, not the source ledger: a
    CloudKit parent and child may arrive in separate source batches. Accounting
    receives no accidental dispatch/pricebook scope; its own financial projection
    schema remains required. Standard has no implicit core-field data grant.
    """
    live = {kind: {} for kind in COVERAGE}
    for record in records:
        if not record["deleted"]:
            live[record["kind"]][record["id"]] = record
    role, email = member["member_role"], member["member_email"]
    if role in ("Standard", "Accounting"):
        return []
    office = role in ("Admin", "Dispatcher")
    own = {key for key, value in live["technician"].items() if value["fields"].get("email") == email and value["fields"]["isActive"]}
    if len(own) > 1:
        raise sharing.fail("identity_ambiguous", "Resolve duplicate technician identities before sharing field work.")
    if role == "Field Technician" and not own:
        raise sharing.fail("identity_pending", "The staff technician profile has not arrived. Review the account mapping before declaring an empty work list.")
    jobs = {key for key, record in live["job"].items() if office or own.intersection(record["fields"]["assignedTechnicianIDs"])}
    for key in jobs:
        values = live["job"][key]["fields"]
        for name, target in (("customerID", "customer"), ("serviceLocationID", "location"), ("customerEquipmentID", "equipment")):
            reference = values.get(name)
            if reference is None:
                continue
            parent = live[target].get(reference)
            if parent is None:
                raise sharing.fail("relationships_pending", "Related operational records have not arrived. Keep the existing staff snapshot and retry after synchronization.")
            if target != "customer" and parent["fields"]["customerID"] != values["customerID"]:
                raise sharing.fail("relationships_changed", "Review the customer/property/equipment links before sharing work.")
            if target == "equipment" and values.get("serviceLocationID") is not None and parent["fields"].get("serviceLocationID") is not None and values["serviceLocationID"] != parent["fields"]["serviceLocationID"]:
                raise sharing.fail("relationships_changed", "The job and its equipment refer to different properties. Review the original links.")
    customers = set(live["customer"]) if office else {live["job"][key]["fields"]["customerID"] for key in jobs}
    assigned_locations = {live["job"][key]["fields"].get("serviceLocationID") for key in jobs} - {None}
    assigned_equipment = {live["job"][key]["fields"].get("customerEquipmentID") for key in jobs} - {None}
    assigned_locations.update(live["equipment"][key]["fields"]["serviceLocationID"] for key in assigned_equipment
                              if live["equipment"][key]["fields"].get("serviceLocationID") is not None)
    locations = set(live["location"]) if office else assigned_locations
    equipment = set(live["equipment"]) if office else assigned_equipment.union({
        key for key, record in live["equipment"].items()
        if record["fields"]["customerID"] in customers and record["fields"].get("serviceLocationID") in locations})
    technicians = set(live["technician"]) if office else own.union(
        {value for key in jobs for value in live["job"][key]["fields"]["assignedTechnicianIDs"]})
    items = {key for key, record in live["item"].items() if office or
             record["fields"]["reviewStatus"] in ("approved", "archived") or record["fields"].get("createdByEmail") == email}
    selected = {"job": jobs, "customer": customers, "location": locations, "equipment": equipment,
                "technician": technicians, "item": items}
    result = []
    for kind in COVERAGE:
        for key in sorted(selected[kind]):
            if key not in live[kind]:
                raise sharing.fail("relationships_pending", "Related operational records have not arrived. Keep the existing staff snapshot and retry after synchronization.")
            record = live[kind][key]
            values = dict(record["fields"])
            # Field/dispatch pricebooks must not expose purchasing margin data.
            if kind == "item" and role != "Admin":
                values.pop("purchaseCost", None)
            for name, target in (("customerID", "customer"), ("serviceLocationID", "location"), ("customerEquipmentID", "equipment")):
                reference = values.get(name)
                if reference is None:
                    continue
                parent = live[target].get(reference)
                if parent is None or reference not in selected[target]:
                    raise sharing.fail("relationships_pending", "Related operational records have not arrived. Keep the existing staff snapshot and retry after synchronization.")
                if target != "customer" and parent["fields"]["customerID"] != values.get("customerID"):
                    raise sharing.fail("relationships_changed", "Review the customer/property/equipment links before sharing work.")
            if kind == "job":
                if any(value not in live["technician"] for value in values["assignedTechnicianIDs"]):
                    raise sharing.fail("relationships_pending", "The assigned crew has not finished synchronizing.")
                # Cross-job references are navigation hints, never an extra data grant.
                for name in ("originatingServiceCallID", "scheduledFollowUpServiceCallID"):
                    if values.get(name) not in jobs:
                        values.pop(name, None)
            result.append({"kind": kind, "id": key, "revision": record["revision"], "fields": values})
    return result
