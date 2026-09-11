import Foundation

/// Financial and relationship invariants are checked again when recovering a
/// saved proposal, not just when the planner first produces it. This is not an
/// authorization grant; a live caller still needs the server's exclusive claim.
@MainActor enum StaffOwnerInvoiceEvidence {
    static func match(_ line: StaffInvoiceLine, fields: [String: StaffWorkspaceValue]) throws {
        guard fields["name"] == .text(line.name), fields["unitPrice"] == .number(line.unitPrice),
              fields["itemTypeRawValue"] == .text(line.itemType), fields["isTaxable"] == .flag(line.isTaxable),
              fields["itemDescription"] == (line.description.map(StaffWorkspaceValue.text) ?? .null),
              fields["sku"] == (line.sku.map(StaffWorkspaceValue.text) ?? .null),
              fields["pricebookReviewStatusRawValue"] == .null || fields["pricebookReviewStatusRawValue"] == .text("approved")
        else { throw StaffReplicaSourceSyncError.invalid }
    }
    static func validate(_ proposal: StaffOwnerInvoiceProposal, snapshot: CatalogSnapshotPayload.Snapshot,
                         scope: StaffReplicaSourceScope) throws {
        let request = proposal.request, fields = proposal.expectedInvoice.fields
        let records = Dictionary(uniqueKeysWithValues: proposal.dependencies.map { ($0.key, $0) })
        let customer = UUID(uuidString: request.origin.customerID)!, root = UUID(uuidString: request.line.itemID)!
        func include(_ kind: String, _ id: UUID) throws -> StaffWorkspacePublishedRecord {
            guard let record = records[kind + ":" + id.uuidString.lowercased()] else { throw StaffOwnerInvoiceError.missing }
            return record
        }
        _ = try include("customer", customer)
        for (kind, key) in [("job", "serviceCallID"), ("location", "serviceLocationID")] {
            if case .identifier(let id) = fields[key] {
                guard try include(kind, id).fields["customer"] == .identifier(customer) else { throw StaffOwnerInvoiceError.changed }
            }
        }
        if request.line.kind == "new" {
            guard records["item:" + request.line.itemID] == nil else { throw StaffOwnerInvoiceError.changed }
        } else { _ = try include("item", root) }
        func equipment(_ id: UUID) throws {
            guard try include("equipment", id).fields["customer"] == .identifier(customer) else { throw StaffOwnerInvoiceError.changed }
        }
        if let id = request.line.equipmentID.flatMap(UUID.init(uuidString:)) { try equipment(id) }
        func links(_ line: CatalogLineItemSnapshot) throws {
            if line.catalogItemID != root || request.line.kind != "new" { _ = try include("item", line.catalogItemID) }
            if let system = line.servicedEquipment { try equipment(system.equipmentID) }
            if let assembly = line.assembly {
                _ = try include("item", assembly.assemblyItemID)
                for component in assembly.components { _ = try include("item", component.itemID) }
            }
            if let bundle = line.bundle {
                guard bundle.scope.companyID == scope.binding.companyID else { throw StaffOwnerInvoiceError.changed }
                for member in bundle.members { try links(member.line) }
            }
        }
        for line in snapshot.lines { try links(line) }
        let rawBefore = try StaffOwnerInvoicePlanner.text(fields, "catalogSnapshotJSON")
        let before = try CatalogSnapshotPayload.read(rawBefore)
        if let before { try CatalogSnapshotPayload.validateBusinessEvidence(before) }
        let amount = try StaffOwnerInvoicePlanner.number(fields, "amount"), tax = try StaffOwnerInvoicePlanner.number(fields, "salesTaxAmount")
        if before == nil {
            guard amount == 0, tax == 0 else { throw StaffOwnerInvoiceError.manual }
        } else {
            guard let grossAmount = QuickBooksSalesLineContract.decimal(amount, places: 2),
                  let taxAmount = QuickBooksSalesLineContract.decimal(tax, places: 2),
                  let net = BillingTaxPolicy.snapshotSubtotal(rawBefore).flatMap({ QuickBooksSalesLineContract.decimal($0, places: 2) }),
                  grossAmount - taxAmount == net else { throw StaffOwnerInvoiceError.changed }
        }
        let rawAfter = try StaffOwnerInvoicePlanner.text(proposal.invoiceFields, "catalogSnapshotJSON")
        guard rawBefore != rawAfter, let net = BillingTaxPolicy.snapshotSubtotal(rawAfter),
              proposal.invoiceFields["amount"] == .number(net),
              snapshot.taxAddresses == before?.taxAddresses,
              snapshot.discount?.kind == before?.discount?.kind, snapshot.discount?.value == before?.discount?.value,
              snapshot.discount?.reason == before?.discount?.reason,
              snapshot.discount == nil || snapshot.discount?.authorizedByEmail == scope.actorEmail,
              proposal.invoiceFields["taxCalculationStatusRawValue"] == .text(snapshot.lines.flatMap(\.soldLeaves).contains(where: \.isTaxable) ? "pending_quickbooks" : "not_applicable")
        else { throw StaffReplicaSourceSyncError.invalid }
        let previous = Dictionary(uniqueKeysWithValues: (before?.lines ?? []).map { ($0.catalogItemID, $0) })
        let next = Dictionary(uniqueKeysWithValues: snapshot.lines.map { ($0.catalogItemID, $0) })
        let components = snapshot.lines.filter { $0.catalogItemID != root && $0.assembly?.assemblyItemID == root && $0.assembly?.presentation == .itemized }
        let requested: [CatalogLineItemSnapshot]
        if let first = components.first, let recipe = first.assembly {
            guard request.line.kind == "catalog", request.line.itemType == "Service",
                  components.allSatisfy({ $0.assembly == recipe }), Set(components.map(\.catalogItemID)) == Set(recipe.components.map(\.itemID))
            else { throw StaffOwnerInvoiceError.changed }
            requested = components
        } else { requested = snapshot.lines.filter { $0.catalogItemID == root } }
        let affected = Set(requested.map(\.catalogItemID))
        guard !requested.isEmpty, Set(previous.keys).isSubset(of: Set(next.keys)),
              Set(next.keys).subtracting(previous.keys).isSubset(of: affected) else { throw StaffOwnerInvoiceError.changed }
        for (id, line) in previous where !affected.contains(id) {
            guard next[id] == line else { throw StaffOwnerInvoiceError.changed }
        }
        for line in requested {
            guard let requestedUnits = QuickBooksSalesLineContract.decimal(request.line.quantity, places: 5),
                  let actual = QuickBooksSalesLineContract.decimal(line.quantity, places: 5),
                  let old = QuickBooksSalesLineContract.decimal(previous[line.catalogItemID]?.quantity ?? 0, places: 5)
            else { throw StaffOwnerInvoiceError.changed }
            var added = requestedUnits
            if line.catalogItemID != root {
                guard let component = line.assembly?.components.first(where: { $0.itemID == line.catalogItemID }),
                      let units = QuickBooksSalesLineContract.decimal(component.quantity, places: 5) else { throw StaffOwnerInvoiceError.changed }
                added *= units
            }
            guard actual == old + added else { throw StaffOwnerInvoiceError.changed }
            if let prior = previous[line.catalogItemID] {
                guard try StaffOwnerInvoicePlanner.compatible(prior, line) else { throw StaffOwnerInvoiceError.incompatible }
            }
            if let equipment = request.line.equipmentID {
                guard line.servicedEquipment?.equipmentID.uuidString.lowercased() == equipment else { throw StaffOwnerInvoiceError.changed }
            }
        }
    }
}
