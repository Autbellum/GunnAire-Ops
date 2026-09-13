"""Server-owned billing disclosure, compatible with StaffWorkspaceBillingProjection.

Read-only historical evidence, never an instruction to publish, charge, approve,
or import owner models. Original JSON is validated before any role is filtered.
"""
from __future__ import annotations

import copy
import math
import re
import uuid
from decimal import Decimal, ROUND_HALF_UP

try:
    from Backend import staff_workspace_contract as contract, staff_workspace_selection as selection, qbo_change_capture
except ModuleNotFoundError:
    import staff_workspace_contract as contract
    import staff_workspace_selection as selection
    import qbo_change_capture

SCHEMA = "staff-billing-view-v1"
INVOICE = set("quickBooksSyncStatus workTypeRaw lineItemSummary amount salesTaxAmount status createdAt serviceCallID serviceLocationID siteAddress quickBooksID quickBooksBalanceDue quickBooksLastSyncedAt taxCalculationStatusRawValue taxCalculatedAt projectMilestoneID projectMilestoneSequence projectMilestoneTitle projectContractAmount projectBillingPercent dueDate notes customerSignatureName customerSignatureImageBase64 customerSignedAt completionNotes finalizedAt customer".split())
ESTIMATE = set("proposalIsRecommended lineItemSummary amount salesTaxAmount status createdAt serviceCallID serviceLocationID siteAddress scheduledServiceCallID parentEstimateID changeOrderReason proposalGroupID proposalOption quickBooksID taxCalculationStatusRawValue taxCalculatedAt customerApprovedByName customerApprovedAt customerApprovalMethodRaw customerApprovalReference customerApprovalRecordedByEmail customerApprovalSignatureImageBase64 notes customer".split())
SERVICE = set("quickBooksSyncDetail quickBooksPaymentReviewJSON milestoneDraftReceiptJSON".split())
DIRECT = {"Service", "Inventory", "NonInventory"}
MAX_BYTES = 32 * 1024 * 1024


def invalid():
    return selection.failure("billing_evidence_pending")


def require(condition):
    if not condition:
        raise invalid()


def shape(value, required, optional=""):
    required, optional = set(required.split()), set(optional.split())
    require(type(value) is dict and required <= set(value) <= required | optional)
    require(all(value[key] is not None for key in required))
    return value


def text(value, nonempty=False):
    require(type(value) is str and "\0" not in value and (not nonempty or bool(value.strip())))
    return value


def identifier(value):
    text(value)
    try:
        return str(uuid.UUID(value)).upper()
    except ValueError:
        raise invalid() from None


def number(value, low=0, high=99_999_999_999):
    require(type(value) in (int, float) and low <= value <= high and math.isfinite(value))
    return value


def decimal(value, places=5, high=99_999_999_999):
    number(value, high=high)
    value = Decimal(str(value))
    require(value == value.quantize(Decimal(1).scaleb(-places)))
    return value


def cents(value):
    return value.quantize(Decimal(".01"), rounding=ROUND_HALF_UP)


def date(value):
    return number(value, low=-100_000_000_000, high=100_000_000_000)


def flag(value):
    require(type(value) is bool)
    return value


def reference(value):
    text(value)
    require(value not in (".", "..") and re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", value) is not None)
    return value


def array(value, maximum=750):
    require(type(value) is list and len(value) <= maximum)
    return value


def optional(value, key, validator):
    if value.get(key) is not None:
        value[key] = validator(value[key])


def parse(raw):
    text(raw)
    require(len(raw.encode()) <= 1_048_576)
    try:
        result = qbo_change_capture.strict_json(raw)
    except (ValueError, TypeError, RecursionError):
        raise invalid() from None
    pending, nodes = [(result, 0)], 0
    while pending:
        value, depth = pending.pop()
        nodes += 1
        require(depth <= 16 and nodes <= 100_000)
        if type(value) is dict:
            for key in value:
                text(key)
            pending.extend((child, depth + 1) for child in value.values())
        elif type(value) is list:
            pending.extend((child, depth + 1) for child in value)
        elif type(value) is str:
            text(value)
        elif type(value) in (int, float):
            number(value, low=-1e100, high=1e100)
        else:
            require(value is None or type(value) is bool)
    return result


def disclosure(value, financial):
    if not financial:
        return {"restricted": {}}
    return {"notRecorded": {}} if value is None else {"recorded": {"_0": value}}


def coverage():
    require(contract.SCHEMA_DIGEST == selection.OWNER_DIGEST)
    require(INVOICE | SERVICE | {"catalogSnapshotJSON"} == set(contract.SPECS["invoice"]))
    require(ESTIMATE | {"catalogSnapshotJSON"} == set(contract.SPECS["estimate"]))
    require(not INVOICE & SERVICE)


class Catalog:
    def __init__(self, graph, record):
        self.graph, self.record, self.count = graph, record, 0

    def value(self, name):
        return self.graph.value(self.record["kind"], self.record["id"], name)

    def linked(self, kind, key):
        key = identifier(key)
        require(key.lower() in self.graph.live[kind])
        return key

    def line(self, value, member=False):
        self.count += 1
        require(self.count <= 750)
        result = copy.deepcopy(shape(value, "catalogItemID name unitPrice isTaxable catalogUpdatedAt",
            "itemTypeRawValue quickBooksItemID description sku pricebookUnitPrice purchaseCost quantity priceAdjustmentReason priceAdjustmentAuthorizedByEmail priceAdjustmentAuthorizedAt servicedEquipment assembly bundle"))
        result["catalogItemID"] = self.linked("item", result["catalogItemID"])
        text(result["name"], True)
        flag(result["isTaxable"])
        date(result["catalogUpdatedAt"])
        price = decimal(result["unitPrice"])
        # Only absent historical fields have the native decoder's defaults.
        result.setdefault("quantity", 1)
        result.setdefault("pricebookUnitPrice", result["unitPrice"])
        quantity = decimal(result["quantity"], high=999_999)
        book = decimal(result["pricebookUnitPrice"])
        require(quantity > 0)
        optional(result, "purchaseCost", number)
        optional(result, "quickBooksItemID", reference)
        for key in ("itemTypeRawValue", "description", "sku", "priceAdjustmentReason", "priceAdjustmentAuthorizedByEmail"):
            optional(result, key, text)
        if result.get("itemTypeRawValue") is not None:
            require(result["itemTypeRawValue"] in DIRECT | {"Group"})
        adjustment = ("priceAdjustmentReason", "priceAdjustmentAuthorizedByEmail", "priceAdjustmentAuthorizedAt")
        if any(result.get(key) is not None for key in adjustment) or abs(price - book) >= Decimal(".005"):
            text(result.get(adjustment[0]), True)
            text(result.get(adjustment[1]), True)
            date(result.get(adjustment[2]))
        if result.get("servicedEquipment") is not None:
            equipment = shape(result["servicedEquipment"], "equipmentID name", "equipmentType manufacturer modelNumber serialNumber location")
            equipment["equipmentID"] = self.linked("equipment", equipment["equipmentID"])
            text(equipment["name"], True)
            for key in set(equipment) - {"equipmentID", "name"}:
                optional(equipment, key, text)
            require(self.graph.value("equipment", equipment["equipmentID"].lower(), "customer") == self.value("customer"))
        if result.get("assembly") is not None:
            require(not member and result.get("bundle") is None)
            assembly = shape(result["assembly"], "assemblyItemID name revision presentation components")
            assembly["assemblyItemID"] = self.linked("item", assembly["assemblyItemID"])
            text(assembly["name"], True)
            contract.integer(assembly["revision"], 1)
            require(assembly["presentation"] in ("flat_rate", "itemized"))
            if assembly["presentation"] == "flat_rate":
                require(assembly["assemblyItemID"] == result["catalogItemID"])
            components = array(assembly["components"])
            require(bool(components))
            seen = set()
            for component in components:
                shape(component, "itemID name quantity tracksInventory", "sku purchaseCost")
                component["itemID"] = self.linked("item", component["itemID"])
                require(component["itemID"] not in seen)
                seen.add(component["itemID"])
                text(component["name"], True)
                require(number(component["quantity"], high=999_999) > 0)
                flag(component["tracksInventory"])
                optional(component, "sku", text)
                optional(component, "purchaseCost", number)
        total = cents(price * quantity)
        if result.get("bundle") is not None or result.get("itemTypeRawValue") == "Group":
            require(not member and result.get("assembly") is None and result.get("itemTypeRawValue") == "Group")
            reference(result.get("quickBooksItemID"))
            bundle = shape(result.get("bundle"), "scope printGroupedItems members")
            scope = shape(bundle["scope"], "companyID realmID environment")
            scope["companyID"] = identifier(scope["companyID"])
            require(scope["companyID"].lower() == self.record["companyID"])
            reference(scope["realmID"])
            require(scope["environment"] in ("sandbox", "production"))
            flag(bundle["printGroupedItems"])
            members = array(bundle["members"], 749)
            require(bool(members))
            seen, total = set(), Decimal(0)
            for entry in members:
                shape(entry, "id line tracksInventory")
                entry["id"] = identifier(entry["id"])
                require(entry["id"] not in seen)
                seen.add(entry["id"])
                flag(entry["tracksInventory"])
                entry["line"] = leaf = self.line(entry["line"], member=True)
                require(leaf.get("itemTypeRawValue") in DIRECT and leaf["catalogItemID"] != result["catalogItemID"])
                reference(leaf.get("quickBooksItemID"))
                require(leaf["quickBooksItemID"] != result["quickBooksItemID"])
                # Member quantities already include the sold root quantity.
                total += Decimal(str(leaf["extendedAmount"]))
        require(total <= 99_999_999_999)
        result["extendedAmount"] = float(total)
        # Match Swift encodeIfPresent: explicit nulls are not emitted as fields.
        return {key: val for key, val in result.items() if val is not None}

    def addresses(self, value):
        shape(value, "version scope service origin reviewedAt")
        require(type(value["version"]) is int and value["version"] == 1)
        date(value["reviewedAt"])
        scope = shape(value["scope"], "customerID", "serviceLocationID siteAddress")
        scope["customerID"] = self.linked("customer", scope["customerID"])
        require(scope["customerID"].lower() == self.value("customer"))
        if scope.get("serviceLocationID") is not None:
            scope["serviceLocationID"] = self.linked("location", scope["serviceLocationID"])
        require((scope.get("serviceLocationID") or "").lower() == (self.value("serviceLocationID") or ""))
        site = self.value("siteAddress")
        site = (site.strip() or None) if site is not None else None
        require(scope.get("siteAddress") == site)
        states = set("AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY AS GU MP PR VI AA AE AP".split())
        for key in ("service", "origin"):
            address = shape(value[key], "Line1 City CountrySubDivisionCode PostalCode Country")
            for name, limit in (("Line1", 500), ("City", 255), ("CountrySubDivisionCode", 2), ("PostalCode", 10), ("Country", 3)):
                clean = text(address[name], True).strip()
                require(len(clean) <= limit and not any(ord(c) < 32 or ord(c) == 127 for c in clean))
            require(address["CountrySubDivisionCode"].strip().upper() in states and address["Country"].strip().upper() in ("US", "USA"))
            require(re.fullmatch(r"[0-9]{5}(-[0-9]{4})?", address["PostalCode"].strip()) is not None)
        return value

    def read(self, raw):
        value = parse(raw)
        discount, addresses = None, None
        if type(value) is list:
            rows = value
        else:
            shape(value, "version lines", "documentDiscount taxAddresses")
            require(type(value["version"]) is int and value["version"] == 1)
            rows, discount, addresses = value["lines"], value.get("documentDiscount"), value.get("taxAddresses")
        lines = [self.line(row) for row in array(rows)]
        require(bool(lines) and len({line["catalogItemID"] for line in lines}) == len(lines))
        gross = sum((Decimal(str(line["extendedAmount"])) for line in lines), Decimal(0))
        require(gross <= 99_999_999_999)
        deduction = Decimal(0)
        if discount is not None:
            shape(discount, "kind value grossSubtotalAtAuthorization reason authorizedByEmail authorizedAt")
            require(decimal(discount["grossSubtotalAtAuthorization"], 2) == gross)
            text(discount["reason"], True)
            text(discount["authorizedByEmail"], True)
            date(discount["authorizedAt"])
            number(discount["value"])
            require(discount["value"] > 0)
            if discount["kind"] == "percentage":
                require(discount["value"] <= 100)
                deduction = cents(gross * Decimal(str(discount["value"])) / 100)
            else:
                require(discount["kind"] == "fixed_amount")
                deduction = decimal(discount["value"], 2)
                require(deduction <= gross)
        amount, tax = decimal(self.value("amount"), 2), decimal(self.value("salesTaxAmount"), 2)
        require(amount >= tax and gross - deduction == amount - tax)
        result = {"lines": lines}
        if discount is not None:
            result["discount"] = discount
        if addresses is not None:
            result["taxAddresses"] = self.addresses(addresses)
        return result


def project_line(line, financial):
    result = copy.deepcopy(line)
    for key in ("purchaseCost", "quickBooksItemID"):
        result[key] = disclosure(result.get(key), financial)
    if "assembly" in result:
        for component in result["assembly"]["components"]:
            component["purchaseCost"] = disclosure(component.get("purchaseCost"), financial)
    if "bundle" in result:
        result["bundle"]["scope"] = disclosure(result["bundle"]["scope"], financial)
        for member in result["bundle"]["members"]:
            member["line"] = project_line(member["line"], financial)
    return result


def prepare(graph, index, metadata):
    coverage()
    # Index is an authenticated server result, not a sender's role assertion.
    selected = {(r["kind"], r["id"]): r for r in index}
    financial = metadata["memberRole"] in ("Admin", "Accounting")
    documents = []
    for kind in ("estimate", "invoice"):
        for key, record in sorted(graph.live[kind].items()):
            raw = graph.value(kind, key, "catalogSnapshotJSON")
            catalog = Catalog(graph, record).read(raw) if raw is not None else None
            # Validate even hidden original billing graphs before disclosure.
            if (kind, key) not in selected:
                continue
            unavailable = {field: "serviceOnly" for field in SERVICE} if kind == "invoice" else {}
            fields = {}
            for name in INVOICE if kind == "invoice" else ESTIMATE:
                if name == "quickBooksID" and not financial:
                    unavailable[name] = "roleRestricted"
                else:
                    fields[name] = copy.deepcopy(record["fields"][name])
            if catalog is not None:
                catalog["lines"] = [project_line(line, financial) for line in catalog["lines"]]
            documents.append(dict(kind=kind, id=key.upper(), fields=fields, unavailableFields=unavailable,
                                  catalog={"saved": {"_0": catalog}} if catalog is not None else {"notRecorded": {}}))
    result = {key: metadata[key] for key in ("companyID", "environment", "replicaID", "membershipID", "memberRevision", "shareRevision", "projectionPolicy", "sourceSequence")}
    result.update(schema=SCHEMA, documents=documents)
    require(len(contract.wire(result).encode()) <= MAX_BYTES)
    return result
