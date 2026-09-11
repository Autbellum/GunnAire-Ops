"""Immutable staff invoice-line requests. Recording is not a financial write.

The accepted projection and original owner record are retained independently.
Only the author can replay a request; only the approved owner can review its
private base. No QBO, item mapping, owner-source or payment mutation occurs.
"""
from __future__ import annotations

import copy
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

try:
    from Backend import staff_workspace_delivery as delivery, staff_workspace_source as source
    from Backend import staff_owner_field_edits as owner_edits
except ModuleNotFoundError:
    import staff_workspace_delivery as delivery
    import staff_workspace_source as source
    import staff_owner_field_edits as owner_edits

contract, sharing = delivery.contract, delivery.sharing
SCHEMA = "staff-invoice-line-request-v1"
SCOPE = delivery.SCOPE_FIELDS
FIELDS = SCOPE + " schema commandID selectionID sourceSequence contentSHA256 invoiceID invoiceRevision customerID jobID line reason"
LINE = "kind itemID itemRevision itemType name description sku unitPrice quantity isTaxable equipmentID"
RECORD = "companyID environment replicaID schema schemaDigest kind id revision deleted fields"
ITEM_VALUES = (("name", "name", "text", False), ("description", "itemDescription", "text", True),
               ("sku", "sku", "text", True), ("unitPrice", "unitPrice", "number", False),
               ("isTaxable", "isTaxable", "flag", False), ("itemType", "itemTypeRawValue", "text", False))


def initialize_schema(connection):
    connection.execute("""CREATE TABLE IF NOT EXISTS staff_invoice_line_requests (
        command_id TEXT PRIMARY KEY, selection_id TEXT NOT NULL, share_id TEXT NOT NULL,
        actor_email TEXT NOT NULL, invoice_id TEXT NOT NULL, created_at TEXT NOT NULL,
        ciphertext TEXT NOT NULL, company_id TEXT NOT NULL, environment TEXT NOT NULL,
        replica_id TEXT NOT NULL, new_item_id TEXT
    )""")
    connection.execute("""CREATE INDEX IF NOT EXISTS staff_invoice_line_request_share
        ON staff_invoice_line_requests(share_id,invoice_id,actor_email,command_id)""")
    connection.execute("""CREATE UNIQUE INDEX IF NOT EXISTS staff_invoice_line_new_item
        ON staff_invoice_line_requests(company_id,environment,replica_id,new_item_id)
        WHERE new_item_id IS NOT NULL""")


def number(value, maximum):
    if type(value) not in (float, int):
        raise contract.invalid()
    try:
        result = Decimal(str(value))
        if not result.is_finite() or result < 0 or result > maximum or result != result.quantize(Decimal("0.00001")):
            raise ValueError()
        return result
    except (ValueError, InvalidOperation):
        raise contract.invalid() from None


def text(value, maximum, optional=False, normalized=True):
    if optional and value is None:
        return
    if (type(value) is not str or "\0" in value or len(value.encode()) > maximum
            or normalized and (not value.strip() or value != value.strip())):
        raise contract.invalid()


def validate(payload):
    contract.exact(payload, FIELDS)
    if payload["schema"] != SCHEMA:
        raise sharing.fail("schema_changed", "Update the app before sending this saved invoice-line request.", 409)
    sharing.scope(payload)
    for key in ("replicaID", "commandID", "selectionID", "invoiceID", "customerID"):
        sharing.identifier(payload[key])
    if payload["jobID"] is not None:
        sharing.identifier(payload["jobID"])
    sharing.account_hash(payload["contentSHA256"])
    contract.integer(payload["sourceSequence"], 1)
    contract.integer(payload["invoiceRevision"], 1)
    text(payload["reason"], 2000)
    line = payload["line"]
    contract.exact(line, LINE)
    sharing.identifier(line["itemID"])
    if line["equipmentID"] is not None:
        sharing.identifier(line["equipmentID"])
    # New input is normalized; catalog text is an exact historical value, including blank optional text.
    text(line["name"], 200, normalized=line["kind"] == "new")
    if not line["name"].strip():
        raise contract.invalid()
    text(line["description"], 2000, True, normalized=line["kind"] == "new")
    text(line["sku"], 100, True, normalized=line["kind"] == "new")
    if line["kind"] not in ("catalog", "new") or type(line["isTaxable"]) is not bool:
        raise contract.invalid()
    contract.integer(line["itemRevision"], 0)
    if (line["kind"] == "new" and (line["itemRevision"] != 0 or line["itemType"] not in ("Service", "NonInventory"))
            or line["kind"] == "catalog" and (line["itemRevision"] < 1 or line["itemType"] not in ("Service", "NonInventory", "Inventory", "Group"))):
        raise contract.invalid()
    quantity, price = number(line["quantity"], 999_999), number(line["unitPrice"], 99_999_999_999)
    if quantity <= 0 or quantity * price > 99_999_999_999 or len(contract.wire(payload).encode()) > 16_384:
        raise contract.invalid()
    # A group has no standalone sales price; office expands original members.
    return None if line["itemType"] == "Group" else str((quantity * price).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def atom(fields, key, tag, nullable=False):
    value = fields.get(key)
    if nullable and value == {"null": {}}:
        return None
    contract.exact(value, tag)
    contract.exact(value[tag], "_0")
    return value[tag]["_0"]


def identifier_field(fields, key):
    value = atom(fields, key, "identifier", True)
    return value.lower() if value is not None else None


def item_matches(line, fields):
    if atom(fields, "pricebookReviewStatusRawValue", "text", True) not in (None, "approved"):
        return False
    for supplied, field, tag, nullable in ITEM_VALUES:
        value = atom(fields, field, tag, nullable)
        if contract.canonical(line[supplied]) != contract.canonical(value):
            # Swift/Python can spell equal JSON numbers differently; bool/precision are checked first.
            if supplied != "unitPrice" or number(line[supplied], 99_999_999_999) != number(value, 99_999_999_999):
                return False
    return True


def record_hash(value):
    return delivery.digest(contract.wire(value).encode())


class StaffInvoiceLines(delivery.StaffWorkspaceDelivery):
    @staticmethod
    def receipt(request, actor, share_id, created):
        return dict(schema=SCHEMA, request=copy.deepcopy(request), actorEmail=actor, shareID=share_id,
                    createdAt=created, state="recorded", officeReviewRequired=True, qboPublished=False,
                    lineSubtotal=validate(request))

    def saved(self, row):
        saved = self.source.decode(row["ciphertext"])
        try:
            contract.exact(saved, "request receipt baseInvoice baseInvoiceSHA256 baseItem baseItemSHA256")
            request = saved["request"]
            validate(request)
            owner_edits.instant(row["created_at"])
            owner_edits.StaffOwnerFieldEdits.valid_owner_email(row["actor_email"])
            sharing.identifier(row["share_id"])
            if tuple(row[k] for k in ("command_id", "selection_id", "invoice_id")) != tuple(request[k] for k in ("commandID", "selectionID", "invoiceID")):
                raise ValueError()
            if tuple(row[k] for k in ("company_id", "environment", "replica_id")) != tuple(request[k] for k in SCOPE.split()):
                raise ValueError()
            if row["new_item_id"] != (request["line"]["itemID"] if request["line"]["kind"] == "new" else None):
                raise ValueError()
            expected = self.receipt(request, row["actor_email"], row["share_id"], row["created_at"])
            if contract.canonical(expected) != contract.canonical(saved["receipt"]):
                raise ValueError()
            base = saved["baseInvoice"]
            contract.exact(base, RECORD)
            contract.integer(base["revision"], 1)
            if (base["kind"] != "invoice" or base["id"] != request["invoiceID"] or base["revision"] != request["invoiceRevision"]
                    or base["deleted"] is not False or base["schema"] != contract.SCHEMA_VERSION or base["schemaDigest"] != contract.SCHEMA_DIGEST
                    or any(base[key] != request[key] for key in SCOPE.split())):
                raise ValueError()
            contract.validate("invoice", base["fields"])
            if (identifier_field(base["fields"], "customer") != request["customerID"]
                    or identifier_field(base["fields"], "serviceCallID") != request["jobID"]
                    or atom(base["fields"], "status", "text") not in ("unpaid", "overdue")
                    or atom(base["fields"], "finalizedAt", "date", True) is not None
                    or saved["baseInvoiceSHA256"] != record_hash(base)):
                raise ValueError()
            item = saved["baseItem"]
            if request["line"]["kind"] == "new":
                if item is not None or saved["baseItemSHA256"] is not None:
                    raise ValueError()
            else:
                contract.exact(item, RECORD)
                contract.integer(item["revision"], 1)
                if (item["kind"] != "item" or item["id"] != request["line"]["itemID"]
                        or item["revision"] != request["line"]["itemRevision"] or item["deleted"] is not False
                        or any(item[key] != base[key] for key in (SCOPE + " schema schemaDigest").split())
                        or saved["baseItemSHA256"] != record_hash(item)):
                    raise ValueError()
                contract.validate("item", item["fields"])
                if not item_matches(request["line"], item["fields"]):
                    raise ValueError()
        except (sharing.AttemptError, ValueError, KeyError, TypeError, AttributeError, InvalidOperation, RecursionError):
            raise self.source.unavailable() from None
        return saved

    def submit(self, session_id, share_id, operation, payload):
        validate(payload)
        sharing.identifier(share_id)
        sharing.identifier(operation)
        if payload["selectionID"] != operation:
            raise contract.invalid()
        try:
            return self._submit(session_id, share_id, operation, payload)
        except (KeyError, TypeError, AttributeError, InvalidOperation, RecursionError):
            # Persisted projection corruption must not leak a traceback or become a new request.
            raise self.source.unavailable() from None

    def _submit(self, session_id, share_id, operation, payload):
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope, share = self.selection.member_authority(connection, session_id, share_id, payload)
            if (share["member_role"] not in ("Admin", "Accounting", "Field Technician") or actor["email"] != share["member_email"]
                    or actor["role"] != share["member_role"]):
                raise sharing.fail("billing_request_forbidden", "Use the original authorized staff account for invoice-line requests.", 403)
            selection_row = connection.execute("SELECT * FROM staff_workspace_selections WHERE id=? AND share_id=?", (operation, share_id)).fetchone()
            snapshot = self.selection.shared_original(selection_row, scope, share)
            sequence = self.source.sequence(connection, scope)
            self.selection.receipt(snapshot, sequence)
            raw = self.original(connection, operation, snapshot)
            if raw is None:
                raise sharing.fail("content_not_prepared", "Recover the original shared content before sending this request.", 404)
            if payload["sourceSequence"] != snapshot["sourceSequence"] or delivery.digest(raw) != payload["contentSHA256"]:
                raise sharing.fail("content_changed", "Refresh the original shared invoice before sending a new request.", 409)
            existing = connection.execute("SELECT * FROM staff_invoice_line_requests WHERE command_id=?", (payload["commandID"],)).fetchone()
            if existing:
                if existing["actor_email"] != actor["email"] or existing["share_id"] != share_id:
                    raise sharing.fail("request_actor_changed", "Recover this request with its original staff account and share.", 403)
                saved = self.saved(existing)
                if contract.canonical(saved["request"]) != contract.canonical(payload):
                    raise sharing.fail("request_changed", "This request ID already belongs to different saved work.", 409)
                return saved["receipt"]
            if sequence != snapshot["sourceSequence"]:
                raise sharing.fail("source_changed", "Refresh shared work before creating a new invoice-line request.", 409)
            view = delivery.qbo_change_capture.strict_json(raw.decode("utf-8"))
            index = {(r["kind"], r["id"]): r for r in view["records"]}
            invoice = index.get(("invoice", payload["invoiceID"]))
            if invoice is None or invoice["revision"] != payload["invoiceRevision"]:
                raise sharing.fail("invoice_changed", "The original invoice is unavailable or changed.", 409)
            fields = invoice["body"]["billing"]["_0"]["fields"]
            customer, job = atom(fields, "customer", "identifier", True), atom(fields, "serviceCallID", "identifier", True)
            if (customer is None or customer.lower() != payload["customerID"] or (job.lower() if job else None) != payload["jobID"]
                    or share["member_role"] == "Field Technician" and job is None):
                raise sharing.fail("invoice_scope_changed", "Use this invoice's original customer and assigned job.", 409)
            if atom(fields, "status", "text") not in ("unpaid", "overdue") or atom(fields, "finalizedAt", "date", True) is not None:
                raise sharing.fail("invoice_locked", "Ask the office to review changes to this finalized or paid invoice.", 409)
            line = payload["line"]
            if line["kind"] == "catalog":
                item = index.get(("item", line["itemID"]))
                if item is None or item["revision"] != line["itemRevision"]:
                    raise sharing.fail("item_changed", "Refresh the original catalog item before requesting a line.", 409)
                item_fields = item["body"]["operational"]["_0"]["fields"]
                if not item_matches(line, item_fields):
                    raise sharing.fail("item_changed", "Use the exact shared catalog values; ask the office to review a price change.", 409)
            else:
                duplicate = connection.execute("SELECT 1 FROM staff_workspace_source_records WHERE " + source.WHERE + " AND kind='item' AND record_id=?", (*scope, line["itemID"])).fetchone()
                if duplicate:
                    raise sharing.fail("item_identity_exists", "This item ID already belongs to an original company item.", 409)
                duplicate = connection.execute("SELECT 1 FROM staff_invoice_line_requests WHERE company_id=? AND environment=? AND replica_id=? AND new_item_id=?", (*scope[:3], line["itemID"])).fetchone()
                if duplicate:
                    raise sharing.fail("item_identity_exists", "This new item ID already belongs to a saved request. Recover the original request.", 409)
            if line["equipmentID"]:
                equipment = index.get(("equipment", line["equipmentID"]))
                if equipment is None or identifier_field(equipment["body"]["operational"]["_0"]["fields"], "customer") != payload["customerID"]:
                    raise sharing.fail("equipment_unavailable", "Select a shared system belonging to this invoice's customer.", 409)
            count = connection.execute("SELECT COUNT(*) FROM staff_invoice_line_requests WHERE share_id=? AND actor_email=? AND invoice_id=?", (share_id, actor["email"], payload["invoiceID"])).fetchone()[0]
            if count >= 128:
                raise sharing.fail("request_capacity", "Keep this draft locally and ask the office to review the saved invoice requests.", 409)
            row = connection.execute("SELECT * FROM staff_workspace_source_records WHERE " + source.WHERE + " AND kind='invoice' AND record_id=?", (*scope, payload["invoiceID"])).fetchone()
            if row is None:
                raise self.source.unavailable()
            base = self.source.decode_record(row)
            if base["deleted"] or base["revision"] != payload["invoiceRevision"] or len(contract.wire(base).encode()) > 1_048_576:
                raise self.source.unavailable()
            if any(contract.canonical(base["fields"][key]) != contract.canonical(value) for key, value in fields.items()):
                raise self.source.unavailable()
            base_item = None
            if line["kind"] == "catalog":
                row = connection.execute("SELECT * FROM staff_workspace_source_records WHERE " + source.WHERE + " AND kind='item' AND record_id=?", (*scope, line["itemID"])).fetchone()
                if row is None:
                    raise self.source.unavailable()
                base_item = self.source.decode_record(row)
                if (base_item["deleted"] or base_item["revision"] != line["itemRevision"]
                        or not item_matches(line, base_item["fields"]) or len(contract.wire(base_item).encode()) > 1_048_576):
                    raise self.source.unavailable()
            receipt = self.receipt(payload, actor["email"], share_id, self.shares.now().isoformat())
            saved = dict(request=copy.deepcopy(payload), receipt=receipt, baseInvoice=base, baseInvoiceSHA256=record_hash(base),
                         baseItem=base_item, baseItemSHA256=record_hash(base_item) if base_item is not None else None)
            connection.execute("INSERT INTO staff_invoice_line_requests VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (payload["commandID"], operation, share_id, actor["email"], payload["invoiceID"], receipt["createdAt"],
                 self.source.encode(saved), *scope[:3], line["itemID"] if line["kind"] == "new" else None))
            self.shares.audit(actor["email"], "record-invoice-line-request", "staff-invoice-line", payload["commandID"], connection=connection)
            return receipt

    def review(self, session_id, command_id, query):
        contract.exact(query, SCOPE if command_id else SCOPE + (" after" if "after" in query else ""))
        if command_id:
            sharing.identifier(command_id)
        after = sharing.identifier(query["after"]) if "after" in query else ""
        with self.shares.database() as connection:
            connection.execute("BEGIN IMMEDIATE")
            initialize_schema(connection)
            actor, scope = self.source.scope(connection, session_id, query)
            sql = """SELECT r.* FROM staff_invoice_line_requests r JOIN staff_workspace_selections s
                ON s.id=r.selection_id AND s.share_id=r.share_id
                AND s.company_id=r.company_id AND s.environment=r.environment AND s.replica_id=r.replica_id
                WHERE r.company_id=? AND r.environment=? AND r.replica_id=?"""
            if command_id:
                row = connection.execute(sql + " AND r.command_id=?", (*scope[:3], command_id)).fetchone()
                if row is None:
                    raise sharing.fail("request_not_found", "This request is not in the current company workspace.", 404)
                saved = self.saved(row)
                if any(saved["request"][key] != query[key] for key in SCOPE.split()):
                    raise self.source.unavailable()
                current_row = connection.execute("SELECT * FROM staff_workspace_source_records WHERE " + source.WHERE + " AND kind='invoice' AND record_id=?", (*scope, row["invoice_id"])).fetchone()
                current = self.source.decode_record(current_row) if current_row else None
                current_item = None
                if saved["baseItem"] is not None:
                    current_row = connection.execute("SELECT * FROM staff_workspace_source_records WHERE " + source.WHERE + " AND kind='item' AND record_id=?", (*scope, saved["request"]["line"]["itemID"])).fetchone()
                    current_item = self.source.decode_record(current_row) if current_row else None
                sequence = self.source.sequence(connection, scope)
                invoice_unchanged = current is not None and contract.canonical(current) == contract.canonical(saved["baseInvoice"])
                item_unchanged = contract.canonical(current_item) == contract.canonical(saved["baseItem"])
                self.shares.audit(actor["email"], "review-invoice-line-request", "staff-invoice-line", command_id, connection=connection)
                return dict(schema=SCHEMA, **saved, currentInvoice=current, currentItem=current_item,
                            invoiceUnchanged=invoice_unchanged, itemUnchanged=item_unchanged, currentSourceSequence=sequence,
                            sourceUnchanged=sequence == saved["request"]["sourceSequence"] and invoice_unchanged and item_unchanged)
            rows = connection.execute(sql + " AND r.command_id>? ORDER BY r.command_id LIMIT 51", (*scope[:3], after)).fetchall()
            for row in rows:
                self.saved(row)
            self.shares.audit(actor["email"], "list-invoice-line-requests", "staff-invoice-line", scope[2], connection=connection)
            return dict(schema=SCHEMA, **{key: query[key] for key in SCOPE.split()},
                        commandIDs=[r["command_id"] for r in rows[:50]], nextCursor=rows[49]["command_id"] if len(rows) > 50 else None)
