import Foundation

/// Builds a reviewable proposal without inserting or changing any live model.
@MainActor enum StaffOwnerInvoicePlanner {
    static func text(_ fields: [String: StaffWorkspaceValue], _ key: String) throws -> String? {
        if fields[key] == .null { return nil }
        guard case .text(let value) = fields[key] else { throw StaffReplicaSourceSyncError.invalid }; return value
    }
    static func identifier(_ fields: [String: StaffWorkspaceValue], _ key: String) throws -> String? {
        if fields[key] == .null { return nil }
        guard case .identifier(let value) = fields[key] else { throw StaffReplicaSourceSyncError.invalid }; return value.uuidString.lowercased()
    }
    static func number(_ fields: [String: StaffWorkspaceValue], _ key: String) throws -> Double {
        guard case .number(let value) = fields[key], value.isFinite else { throw StaffReplicaSourceSyncError.invalid }; return value
    }
    static func item(_ record: StaffWorkspacePublishedRecord) throws -> Item {
        guard let model = record.live, model.kind == "item" else { throw StaffOwnerInvoiceError.missing }
        var resolver = StaffWorkspaceModelResolver()
        return try StaffWorkspaceModelCodecs.item.decodeDetached(model, resolver: &resolver)
    }
    static func make(review: StaffOwnerInvoiceReview, records: [StaffWorkspacePublishedRecord], scope: StaffReplicaSourceScope,
                     reason: String, now: Date = Date(), operation: UUID = UUID()) throws -> StaffOwnerInvoiceProposal {
        try review.validate(scope)
        guard let invoice = review.currentInvoice, !invoice.deleted, records.count <= 100_000,
              Set(records.map(\.key)).count == records.count else { throw StaffOwnerInvoiceError.missing }
        let byKey = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        guard byKey[invoice.key] == invoice else { throw StaffOwnerInvoiceError.changed }
        var required = Set<String>()
        func include(_ kind: String, _ id: String) throws -> StaffWorkspacePublishedRecord {
            let key = kind + ":" + id
            guard let record = byKey[key], !record.deleted else { throw StaffOwnerInvoiceError.missing }
            try record.validate(scope); required.insert(key); return record
        }
        _ = try include("customer", review.request.origin.customerID)
        if let id = review.request.origin.jobID { _ = try include("job", id) }
        if let id = try identifier(invoice.fields, "serviceLocationID") { _ = try include("location", id) }
        let original = try CatalogSnapshotPayload.read(text(invoice.fields, "catalogSnapshotJSON"))
        if let original { try CatalogSnapshotPayload.validateBusinessEvidence(original) }
        else if try number(invoice.fields, "amount") != 0 || number(invoice.fields, "salesTaxAmount") != 0 { throw StaffOwnerInvoiceError.manual }
        var rows = original?.lines ?? []
        func retainLinks(_ line: CatalogLineItemSnapshot) throws {
            _ = try include("item", line.catalogItemID.uuidString.lowercased())
            if let equipment = line.servicedEquipment { _ = try include("equipment", equipment.equipmentID.uuidString.lowercased()) }
            if let assembly = line.assembly {
                _ = try include("item", assembly.assemblyItemID.uuidString.lowercased())
                for component in assembly.components { _ = try include("item", component.itemID.uuidString.lowercased()) }
            }
            for member in line.bundle?.members ?? [] { try retainLinks(member.line) }
        }
        for row in rows { try retainLinks(row) }
        let request = review.request, line = request.line
        var equipment: CatalogLineEquipmentSnapshot?
        if let id = line.equipmentID {
            let record = try include("equipment", id)
            guard try identifier(record.fields, "customer") == request.origin.customerID,
                  let name = try text(record.fields, "name") else { throw StaffOwnerInvoiceError.changed }
            equipment = .init(equipmentID: UUID(uuidString: id)!, name: name,
                equipmentType: try text(record.fields, "equipmentTypeRaw").flatMap(HVACEquipmentType.init(rawValue:))?.displayName,
                manufacturer: try text(record.fields, "manufacturer"), modelNumber: try text(record.fields, "modelNumber"),
                serialNumber: try text(record.fields, "serialNumber"), location: try text(record.fields, "location"))
        }
        var newItem: Item?
        let root: Item
        if line.kind == "new" {
            guard byKey["item:" + line.itemID] == nil, let type = CatalogItemType(rawValue: line.itemType) else { throw StaffOwnerInvoiceError.changed }
            let value = Item(id: UUID(uuidString: line.itemID)!, pricebookCreatedByEmail: review.receipt.actorEmail,
                pricebookReviewedByEmail: scope.actorEmail, pricebookReviewedAt: now, name: line.name, itemType: type,
                unitPrice: line.unitPrice, isTaxable: line.isTaxable, itemDescription: line.description, sku: line.sku, createdAt: now)
            newItem = value; root = value
        } else {
            let record = try include("item", line.itemID)
            guard record == review.currentItem else { throw StaffOwnerInvoiceError.changed }
            root = try item(record)
            guard root.isAvailableForNewWork, root.itemTypeRawValue == line.itemType else { throw StaffOwnerInvoiceError.changed }
        }
        var catalog: [Item] = [root]
        if let raw = root.flatRateAssemblyJSON {
            guard let definition = CatalogAssemblyDefinition.decoded(from: raw) else { throw CatalogSnapshotPayload.Invalid.evidence }
            for component in definition.components { catalog.append(try item(include("item", component.itemID.uuidString.lowercased()))) }
        }
        let additions: [CatalogLineItemSnapshot]
        if root.itemType == .group {
            guard let qbScope = CatalogBundlePolicy.scope(of: root), qbScope.companyID == scope.binding.companyID,
                  let recipe = root.catalogDetails?.group else { throw CatalogBundleError.refreshRequired }
            for part in recipe.ItemGroupLine {
                let matches = records.filter { $0.kind == "item" && !$0.deleted && $0.fields["quickBooksID"] == .text(part.ItemRef.value) }
                guard matches.count == 1, let record = matches.first else { throw CatalogBundleError.refreshRequired }
                if !catalog.contains(where: { $0.id.uuidString.lowercased() == record.id }) { catalog.append(try item(include("item", record.id))) }
            }
            let grouped = try CatalogBundlePolicy.resolve(root: root, catalog: catalog, scope: qbScope)
            additions = [try CatalogBundlePolicy.resized(grouped, quantity: line.quantity).replacingEquipment(equipment)]
        } else {
            let selected = try CatalogAssemblyPolicy.selection(root: root, catalogItems: catalog)
            additions = try selected.lineItems.map { item in
                guard item.isAvailableForNewWork,
                      let units = QuickBooksSalesLineContract.decimal(selected.quantities[item.id] ?? 1, places: 5),
                      let requested = QuickBooksSalesLineContract.decimal(line.quantity, places: 5) else { throw StaffOwnerInvoiceError.changed }
                let price: AuthorizedLinePriceAdjustment? = item.id == root.id && item.unitPrice != line.unitPrice
                    ? .init(pricebookUnitPrice: item.unitPrice, unitPrice: line.unitPrice, reason: reason, authorizedByEmail: scope.actorEmail, authorizedAt: now) : nil
                return CatalogLineItemSnapshot(item: item, quantity: QuickBooksSalesLineContract.double(units * requested),
                    priceAdjustment: price, servicedEquipment: equipment, assembly: selected.assemblySnapshots[item.id])
            }
        }
        for addition in additions {
            if let index = rows.firstIndex(where: { $0.catalogItemID == addition.catalogItemID }) {
                guard try compatible(rows[index], addition),
                      let prior = QuickBooksSalesLineContract.decimal(rows[index].quantity, places: 5),
                      let added = QuickBooksSalesLineContract.decimal(addition.quantity, places: 5) else { throw StaffOwnerInvoiceError.incompatible }
                let quantity = QuickBooksSalesLineContract.double(prior + added)
                rows[index] = rows[index].bundle == nil ? rows[index].replacingQuantity(with: quantity) : try CatalogBundlePolicy.resized(rows[index], quantity: quantity)
            } else { rows.append(addition) }
        }
        let gross = try rows.reduce(Decimal.zero) { total, row in
            guard let amount = QuickBooksSalesLineContract.decimal(row.extendedAmount, places: 2) else { throw CatalogSnapshotPayload.Invalid.evidence }
            return total + amount
        }
        let discount = original?.discount.map { value in
            AuthorizedDocumentDiscount(kind: value.kind, value: value.value, grossSubtotalAtAuthorization: QuickBooksSalesLineContract.double(gross),
                reason: value.reason, authorizedByEmail: scope.actorEmail, authorizedAt: now)
        }
        var deduction = Decimal.zero
        if let discount {
            guard let amount = discount.amount(for: QuickBooksSalesLineContract.double(gross)),
                  let value = QuickBooksSalesLineContract.decimal(amount, places: 2) else { throw BillingDocumentDiscountError.scopeChanged }
            deduction = value
        }
        struct Envelope: Encodable {
            let version = 1
            let lines: [CatalogLineItemSnapshot]
            let documentDiscount: AuthorizedDocumentDiscount?
            let taxAddresses: BillingTaxAddressContext?
        }
        let bytes = try StaffWorkspacePublicationContract.encode(Envelope(lines: rows, documentDiscount: discount, taxAddresses: original?.taxAddresses))
        guard let raw = String(data: bytes, encoding: .utf8), let parsed = try CatalogSnapshotPayload.read(raw) else { throw CatalogSnapshotPayload.Invalid.evidence }
        try CatalogSnapshotPayload.validateBusinessEvidence(parsed)
        var fields = invoice.fields
        fields["catalogSnapshotJSON"] = .text(raw)
        fields["lineItemSummary"] = .text(rows.map { "\($0.quantity.formatted()) × \($0.name)" }.joined(separator: "\n"))
        fields["amount"] = .number(QuickBooksSalesLineContract.double(gross - deduction)); fields["salesTaxAmount"] = .number(0)
        fields["taxCalculationStatusRawValue"] = .text(rows.flatMap(\.soldLeaves).contains(where: \.isTaxable) ? "pending_quickbooks" : "not_applicable")
        fields["quickBooksSyncStatus"] = .text(invoice.fields["quickBooksID"] == .null ? "pending" : "balance_needs_refresh")
        fields["quickBooksSyncDetail"] = .text("Office-approved field items saved. Review tax and mappings before publishing the updated invoice to QuickBooks.")
        for key in ["taxCalculatedAt", "customerSignatureName", "customerSignatureImageBase64", "customerSignedAt"] { fields[key] = .null }
        let proposal = StaffOwnerInvoiceProposal(schema: StaffOwnerInvoiceProposal.schema, companyID: request.origin.companyID,
            environment: request.origin.environment, replicaID: request.origin.replicaID, commandID: request.commandID,
            operationID: operation.uuidString.lowercased(), ownerStoreID: scope.storeUUID.lowercased(), request: request,
            expectedInvoice: invoice, invoiceFields: fields, newItemFields: try newItem.map { try StaffWorkspaceModelCodecs.item.encode($0).fields },
            dependencies: required.sorted().compactMap { byKey[$0] }, reviewed: true, reason: reason)
        try proposal.validate(scope, original: review); return proposal
    }

    /// Do not reprice or reassign an earlier sale when adding another quantity.
    /// Current catalog timestamps may change, but all sold business facts must agree.
    static func compatible(_ original: CatalogLineItemSnapshot, _ addition: CatalogLineItemSnapshot) throws -> Bool {
        func evidence(_ line: CatalogLineItemSnapshot) throws -> Data {
            let unit = line.bundle == nil ? line.replacingQuantity(with: 1) : try CatalogBundlePolicy.resized(line, quantity: 1)
            guard var json = try JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(unit)) as? [String: Any] else { throw CatalogSnapshotPayload.Invalid.evidence }
            json.removeValue(forKey: "catalogUpdatedAt")
            if var bundle = json["bundle"] as? [String: Any], let members = bundle["members"] as? [[String: Any]] {
                bundle["members"] = members.map { raw in
                    var member = raw; member.removeValue(forKey: "id")
                    if var leaf = member["line"] as? [String: Any] { leaf.removeValue(forKey: "catalogUpdatedAt"); member["line"] = leaf }; return member
                }; json["bundle"] = bundle
            }
            return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return try evidence(original) == evidence(addition)
    }
}
