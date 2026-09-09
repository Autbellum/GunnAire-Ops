import Foundation

enum CatalogBundleError: LocalizedError, Equatable {
    case refreshRequired, invalidMembers, invalidQuantity, originalBusiness, lastMember
    var errorDescription: String? {
        switch self {
        case .refreshRequired: "Refresh the QuickBooks catalog for this business before adding this bundle. Every included item needs one active, reviewed mapping."
        case .invalidMembers: "This bundle has incomplete or conflicting included items. The saved draft has been kept; review its items before publishing."
        case .invalidQuantity: "Enter a positive quantity with up to five decimal places. The resulting included quantities must also fit that precision."
        case .originalBusiness: "This saved bundle belongs to a different business or QuickBooks company. Return to its original workspace."
        case .lastMember: "A bundle needs at least one included item. Remove the whole bundle to leave it off this document."
        }
    }
}

/// Member identity is a sold row, not a product ID. Two appearances of the same
/// product can have independent quantities, prices, tax and equipment evidence.
struct CatalogBundleSnapshot: Codable, Equatable {
    struct Member: Codable, Equatable, Identifiable {
        let id: UUID
        let line: CatalogLineItemSnapshot
        let tracksInventory: Bool
    }
    let scope: QuickBooksChangeHistoryScope
    let printGroupedItems: Bool
    let members: [Member]

    func replacingMembers(_ members: [Member]) -> Self {
        .init(scope: scope, printGroupedItems: printGroupedItems, members: members)
    }
}

@MainActor
enum CatalogBundlePolicy {
    static func scope(of item: Item) -> QuickBooksChangeHistoryScope? {
        guard let json = item.quickBooksCatalogReceiptJSON,
              let receipt = try? QuickBooksCatalogApplicationReceipt.decode(json),
              receipt.projectionVersion == 2,
              receipt.isCurrent(on: item, scope: receipt.source.scope) else { return nil }
        return receipt.source.scope
    }

    static func resolve(root: Item, catalog: [Item], scope expected: QuickBooksChangeHistoryScope) throws -> CatalogLineItemSnapshot {
        try expected.validate()
        guard root.itemType == .group, root.isAvailableForNewWork, scope(of: root) == expected,
              let groupID = root.quickBooksID, QuickBooksSalesLineContract.validReference(groupID),
              catalog.filter({ $0.id == root.id }).count == 1,
              let details = root.catalogDetails, let recipe = details.group,
              let printMembers = details.printGroupedItems,
              !recipe.ItemGroupLine.isEmpty, recipe.ItemGroupLine.count < 750 else {
            throw CatalogBundleError.refreshRequired
        }
        try QuickBooksCatalogMappingIntegrity.validateDocumentItems([root], against: catalog)
        let byReference = Dictionary(grouping: catalog.filter { $0.quickBooksID != nil }, by: { $0.quickBooksID! })
        let members = try recipe.ItemGroupLine.map { component -> CatalogBundleSnapshot.Member in
            guard component.ItemRef.value != groupID,
                  let matches = byReference[component.ItemRef.value], matches.count == 1,
                  let item = matches.first, item.itemType.isDirectSalesItem, item.isAvailableForNewWork,
                  item.assemblyDefinition == nil, scope(of: item) == expected,
                  catalog.filter({ $0.id == item.id }).count == 1,
                  component.ItemRef.type == nil || component.ItemRef.type == item.itemTypeRawValue else {
                throw CatalogBundleError.refreshRequired
            }
            try validQuantity(component.Qty)
            let line = CatalogLineItemSnapshot(item: item, quantity: component.Qty)
            guard line.extendedAmount.isFinite else { throw CatalogBundleError.invalidMembers }
            return .init(id: UUID(), line: line, tracksInventory: item.tracksInventory || item.itemType == .inventory)
        }
        let snapshot = CatalogLineItemSnapshot(item: root,
            bundle: .init(scope: expected, printGroupedItems: printMembers, members: members))
        try validate(snapshot)
        return snapshot
    }

    static func validate(_ root: CatalogLineItemSnapshot) throws {
        guard root.itemTypeRawValue == CatalogItemType.group.rawValue,
              let reference = root.quickBooksItemID, QuickBooksSalesLineContract.validReference(reference),
              root.assembly == nil, let bundle = root.bundle,
              !bundle.members.isEmpty, bundle.members.count < 750,
              Set(bundle.members.map(\.id)).count == bundle.members.count else {
            throw CatalogBundleError.invalidMembers
        }
        try bundle.scope.validate()
        try validQuantity(root.quantity)
        for member in bundle.members {
            let leaf = member.line
            guard leaf.bundle == nil, leaf.assembly == nil, leaf.catalogItemID != root.catalogItemID,
                  CatalogItemType(rawValue: leaf.itemTypeRawValue ?? "")?.isDirectSalesItem == true,
                  let id = leaf.quickBooksItemID, id != reference, QuickBooksSalesLineContract.validReference(id),
                  leaf.extendedAmount.isFinite, leaf.extendedAmount >= 0,
                  leaf.purchaseCost.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw CatalogBundleError.invalidMembers
            }
            try validQuantity(leaf.quantity)
        }
        guard root.extendedAmount.isFinite, root.extendedAmount <= 99_999_999_999 else {
            throw CatalogBundleError.invalidMembers
        }
    }

    static func validateScope(_ json: String?, expected: QuickBooksChangeHistoryScope) throws {
        for root in try CatalogSnapshotPayload.read(json)?.lines ?? [] where root.bundle != nil {
            try validate(root)
            guard root.bundle?.scope == expected else { throw CatalogBundleError.originalBusiness }
        }
    }

    static func equipment(_ root: CatalogLineItemSnapshot, _ equipment: CatalogLineEquipmentSnapshot?) -> CatalogLineItemSnapshot {
        guard let bundle = root.bundle else { return root.replacingEquipment(equipment) }
        let members = bundle.members.map {
            CatalogBundleSnapshot.Member(id: $0.id, line: $0.line.replacingEquipment(equipment), tracksInventory: $0.tracksInventory)
        }
        return root.replacingBundle(bundle.replacingMembers(members)).replacingEquipment(equipment)
    }

    /// Changing the customer is an explicit new document context. Never carry
    /// another customer's system/serial into it. A same-customer reopen keeps
    /// the original sold equipment evidence even if that system was archived.
    static func equipmentForCustomerChange(
        in snapshots: [UUID: CatalogLineItemSnapshot],
        from originalCustomerID: UUID?, to customerID: UUID?,
        defaultEquipment: CatalogLineEquipmentSnapshot?
    ) -> [UUID: CatalogLineItemSnapshot] {
        guard originalCustomerID != customerID else { return snapshots }
        return snapshots.mapValues { equipment($0, customerID == nil ? nil : defaultEquipment) }
    }

    static func validateRestoration(_ json: String?, catalog: [Item]) throws {
        let decoded: CatalogSnapshotPayload.Snapshot?
        do { decoded = try CatalogSnapshotPayload.read(json) }
        catch { throw CatalogBundleError.invalidMembers }
        guard let snapshot = decoded else { return }
        let snapshots = snapshot.lines
        guard !snapshots.isEmpty, Set(snapshots.map(\.catalogItemID)).count == snapshots.count else {
            throw CatalogBundleError.invalidMembers
        }
        for root in snapshots {
            guard catalog.filter({ $0.id == root.catalogItemID }).count == 1 else {
                throw CatalogBundleError.invalidMembers
            }
            if root.bundle != nil || root.itemTypeRawValue == CatalogItemType.group.rawValue { try validate(root) }
        }
    }

    static func resized(_ root: CatalogLineItemSnapshot, quantity: Double) throws -> CatalogLineItemSnapshot {
        try validate(root); try validQuantity(quantity)
        guard let bundle = root.bundle,
              let prior = QuickBooksSalesLineContract.decimal(root.quantity, places: 5),
              let next = QuickBooksSalesLineContract.decimal(quantity, places: 5) else { throw CatalogBundleError.invalidQuantity }
        let members = try bundle.members.map { member -> CatalogBundleSnapshot.Member in
            guard let qty = QuickBooksSalesLineContract.decimal(member.line.quantity, places: 5) else {
                throw CatalogBundleError.invalidQuantity
            }
            let value = QuickBooksSalesLineContract.double(qty * next / prior)
            try validQuantity(value)
            return .init(id: member.id, line: member.line.replacingQuantity(with: value), tracksInventory: member.tracksInventory)
        }
        let result = root.replacingBundle(bundle.replacingMembers(members), quantity: quantity)
        try validate(result)
        return result
    }

    static func editMember(_ root: CatalogLineItemSnapshot, memberID: UUID, quantity: Double?) throws -> CatalogLineItemSnapshot {
        try validate(root)
        guard let bundle = root.bundle, bundle.members.contains(where: { $0.id == memberID }) else {
            throw CatalogBundleError.invalidMembers
        }
        if let quantity { try validQuantity(quantity) }
        else if bundle.members.count == 1 { throw CatalogBundleError.lastMember }
        let members = bundle.members.compactMap { member -> CatalogBundleSnapshot.Member? in
            guard member.id == memberID else { return member }
            return quantity.map { .init(id: member.id, line: member.line.replacingQuantity(with: $0), tracksInventory: member.tracksInventory) }
        }
        let result = root.replacingBundle(bundle.replacingMembers(members))
        try validate(result)
        return result
    }

    static func editSale(_ root: CatalogLineItemSnapshot, memberID: UUID, quantity: Double,
                         price: Double, taxable: Bool, reason: String,
                         actorEmail: String?, users: [AppUser]) throws -> CatalogLineItemSnapshot {
        try validate(root); try validQuantity(quantity)
        guard let bundle = root.bundle, let member = bundle.members.first(where: { $0.id == memberID }),
              QuickBooksSalesLineContract.decimal(price, places: 5) != nil else { throw CatalogBundleError.invalidMembers }
        let changed = price != member.line.unitPrice || taxable != member.line.isTaxable
        var adjustment: AuthorizedLinePriceAdjustment?
        if changed {
            guard AppAccess.canAuthorizePriceAdjustments(email: actorEmail, users: users),
                  let actorEmail, !actorEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BillingPriceAdjustmentError.unauthorized
            }
            let note = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty, note.count <= 240 else { throw BillingPriceAdjustmentError.missingReason }
            adjustment = .init(pricebookUnitPrice: member.line.pricebookUnitPrice, unitPrice: price,
                reason: note, authorizedByEmail: actorEmail, authorizedAt: Date())
        }
        let members = bundle.members.map { value -> CatalogBundleSnapshot.Member in
            guard value.id == memberID else { return value }
            return .init(id: value.id,
                line: value.line.replacingSale(quantity: quantity, adjustment: adjustment, taxable: taxable),
                tracksInventory: value.tracksInventory)
        }
        let result = root.replacingBundle(bundle.replacingMembers(members))
        try validate(result)
        return result
    }

    static func validQuantity(_ value: Double) throws {
        guard let quantity = QuickBooksSalesLineContract.decimal(value, places: 5, maximum: 999_999), quantity > 0 else {
            throw CatalogBundleError.invalidQuantity
        }
    }
}
