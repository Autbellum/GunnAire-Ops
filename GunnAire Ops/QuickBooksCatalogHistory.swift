import Foundation
import CryptoKit

enum QuickBooksCatalogImportError: LocalizedError {
    case unsavedEdits

    var errorDescription: String? {
        "Save or cancel the current edits before refreshing QuickBooks. No records were imported."
    }
}

/// A verified read batch. It carries only version metadata and a digest of the
/// typed provider record; canonical accounting history stays on the server.
struct QuickBooksCatalogHistoryBatch {
    struct Version: Codable, Equatable {
        let scope: QuickBooksChangeHistoryScope
        let connectionRevision: String
        let entityID: String
        let updatedAt: String
        let payloadSHA256: String
        let syncToken: String?
        let recordSHA256: String

        func validate() throws {
            try scope.validate()
            _ = try QuickBooksHistoryTimestamp(updatedAt)
            guard QuickBooksChangeHistoryScope.validReference(entityID),
                  QuickBooksChangeHistoryScope.validDigest(connectionRevision),
                  QuickBooksChangeHistoryScope.validDigest(payloadSHA256),
                  QuickBooksChangeHistoryScope.validDigest(recordSHA256),
                  syncToken.map(QuickBooksChangeHistoryScope.validReference) == true
            else { throw QuickBooksChangeHistoryError.invalid }
        }
    }

    let scope: QuickBooksChangeHistoryScope
    private let versions: [String: Version]

    init(scope: QuickBooksChangeHistoryScope, connectionRevision: String,
         versions: [QuickBooksHistoryVersion]) throws {
        try scope.validate()
        guard QuickBooksChangeHistoryScope.validDigest(connectionRevision) else {
            throw QuickBooksChangeHistoryError.invalid
        }
        self.scope = scope
        var mapped: [String: Version] = [:]
        for version in versions {
            _ = try version.validate()
            guard version.status == "present", mapped[version.entityID] == nil else {
                throw QuickBooksChangeHistoryError.lifecycleReview
            }
            let record = try JSONDecoder().decode(QuickBooksItem.self, from: Data(version.recordJSON.utf8))
            let entry = Version(scope: scope, connectionRevision: connectionRevision,
                entityID: version.entityID, updatedAt: version.updatedAt,
                payloadSHA256: version.payloadSHA256, syncToken: record.SyncToken,
                recordSHA256: try QuickBooksCatalogApplicationReceipt.digest(record))
            try entry.validate()
            mapped[version.entityID] = entry
        }
        self.versions = mapped
    }

    func validate(records: [QuickBooksItem]) throws {
        guard records.count == versions.count, Set(records.map(\.Id)).count == records.count,
              Set(records.map(\.Id)) == Set(versions.keys) else { throw QuickBooksChangeHistoryError.invalid }
        for record in records { _ = try version(for: record) }
    }

    func version(for record: QuickBooksItem) throws -> Version {
        if record.ItemType == CatalogItemType.inventory.rawValue {
            try QuickBooksCatalogDetails(record).validateInventory()
        }
        guard let version = versions[record.Id],
              try QuickBooksCatalogApplicationReceipt.digest(record) == version.recordSHA256 else {
            throw QuickBooksChangeHistoryError.changed
        }
        return version
    }
}

/// Version 2 also attests read-only inventory/accounts/hierarchy/bundle detail.
/// Version 1 receipts remain verifiable with their original projection. Neither
/// version claims stock movements or financial events applied. A receipt is neither
/// a server attestation nor proof of delivery to another CloudKit device.
struct QuickBooksCatalogApplicationReceipt: Codable {
    let projectionVersion: Int
    let localItemID: UUID
    let source: QuickBooksCatalogHistoryBatch.Version
    let projectionSHA256: String
    let appliedAt: Date

    private struct Projection: Encodable {
        let quickBooksID: String?
        let name: String
        let itemType: String
        let unitPrice: Double
        let purchaseCost: Double?
        let taxable: Bool
        let description: String?
        let sku: String?
        let purchaseDescription: String?
        let vendorName: String?
        let vendorID: String?
        let reviewStatus: String?
        let catalogDetailsJSON: String?

        init(_ item: Item, version: Int = 2) {
            quickBooksID = item.quickBooksID; name = item.name; itemType = item.itemTypeRawValue
            unitPrice = item.unitPrice; purchaseCost = item.purchaseCost; taxable = item.isTaxable
            description = item.itemDescription; sku = item.sku; purchaseDescription = item.purchaseDescription
            vendorName = item.preferredVendorName; vendorID = item.preferredVendorQuickBooksID
            reviewStatus = item.pricebookReviewStatusRawValue
            catalogDetailsJSON = version >= 2 ? item.quickBooksCatalogDetailsJSON : nil
        }

        func restore(to item: Item) {
            item.quickBooksID = quickBooksID; item.name = name; item.itemTypeRawValue = itemType
            item.unitPrice = unitPrice; item.purchaseCost = purchaseCost; item.isTaxable = taxable
            item.itemDescription = description; item.sku = sku; item.purchaseDescription = purchaseDescription
            item.preferredVendorName = vendorName; item.preferredVendorQuickBooksID = vendorID
            item.pricebookReviewStatusRawValue = reviewStatus
            item.quickBooksCatalogDetailsJSON = catalogDetailsJSON
        }
    }

    /// SwiftData rollback restores storage but can leave an already-held model
    /// showing its failed candidate values. Restore the import-owned fields
    /// before rolling the context back, including the matching receipt.
    static func captureRollback(_ item: Item) -> () -> Void {
        { [projection = Projection(item), status = item.quickBooksSyncStatus,
           detail = item.quickBooksSyncDetail, syncedAt = item.quickBooksLastSyncedAt,
           receipt = item.quickBooksCatalogReceiptJSON] in
            projection.restore(to: item)
            item.quickBooksSyncStatus = status; item.quickBooksSyncDetail = detail
            item.quickBooksLastSyncedAt = syncedAt; item.quickBooksCatalogReceiptJSON = receipt
        }
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ json: String) throws -> Self {
        guard json.utf8.count <= 8192 else { throw QuickBooksChangeHistoryError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        try value.source.validate()
        guard [1, 2].contains(value.projectionVersion),
              QuickBooksChangeHistoryScope.validDigest(value.projectionSHA256),
              value.appliedAt.timeIntervalSince1970.isFinite else { throw QuickBooksChangeHistoryError.invalid }
        return value
    }

    func matchesProjection(of item: Item, scope: QuickBooksChangeHistoryScope) -> Bool {
        localItemID == item.id && source.scope == scope && source.entityID == item.quickBooksID &&
        projectionSHA256 == (try? Self.digest(Projection(item, version: projectionVersion)))
    }

    func isCurrent(on item: Item, scope: QuickBooksChangeHistoryScope) -> Bool {
        matchesProjection(of: item, scope: scope) && !item.requiresPricebookReview &&
        !item.hasPendingQuickBooksCatalogUpdate && item.quickBooksSyncStatus == "synced"
    }

    /// Returns an actionable reason without applying/stamping an unresolved
    /// version. Reauthorization in the same realm may restamp identical data;
    /// it must never erase the provider-time ordering barrier.
    static func reviewReason(for item: Item, incoming: QuickBooksCatalogHistoryBatch.Version,
                             record: QuickBooksItem) -> String? {
        if item.requiresPricebookReview { return "Administrator review is required for this field-created item." }
        if item.hasPendingQuickBooksCatalogUpdate { return "Pending local item changes were preserved for administrator review." }
        guard let json = item.quickBooksCatalogReceiptJSON else { return nil }
        guard let prior = try? decode(json), prior.localItemID == item.id,
              prior.source.scope == incoming.scope, prior.source.entityID == incoming.entityID else {
            return "This item's saved QuickBooks version or business mapping needs review. Local values were preserved."
        }
        // An explicit existing catalog-review workflow may already have
        // accepted this exact provider projection. Rebind its dated evidence
        // without overwriting a divergent local edit or weakening time order.
        let projected = Item(name: record.Name, unitPrice: record.UnitPrice ?? 0)
        projected.itemTypeRawValue = item.itemTypeRawValue
        QuickBooksCatalogSnapshotApplication.apply(record, to: projected)
        let incomingDigest = try? digest(Projection(projected))
        let agreesWithIncoming = incomingDigest != nil && incomingDigest == (try? digest(Projection(item)))
        if prior.projectionVersion == 1, let details = item.quickBooksCatalogDetailsJSON,
           details != projected.quickBooksCatalogDetailsJSON {
            return "Inventory or bundle details changed beyond the older saved version. Review them before refreshing."
        }
        guard prior.matchesProjection(of: item, scope: incoming.scope) || agreesWithIncoming else {
            return "This item changed after its last applied QuickBooks version. Review the local changes before refreshing it."
        }
        guard let oldTime = try? QuickBooksHistoryTimestamp(prior.source.updatedAt),
              let newTime = try? QuickBooksHistoryTimestamp(incoming.updatedAt) else {
            return "The saved QuickBooks item version needs review."
        }
        if newTime < oldTime { return "An older QuickBooks item version was withheld. The newer applied values were preserved." }
        if newTime == oldTime && prior.source.payloadSHA256 != incoming.payloadSHA256 {
            return "QuickBooks returned conflicting item versions at the same update time. Review is required."
        }
        return nil
    }

    static func apply(_ record: QuickBooksItem, version: QuickBooksCatalogHistoryBatch.Version,
                      to item: Item, at date: Date = Date()) throws {
        try version.validate()
        guard record.Id == version.entityID, try digest(record) == version.recordSHA256,
              item.quickBooksID == nil || item.quickBooksID == record.Id,
              reviewReason(for: item, incoming: version, record: record) == nil else {
            throw QuickBooksChangeHistoryError.lifecycleReview
        }
        QuickBooksCatalogSnapshotApplication.apply(record, to: item, at: date)
        let receipt = Self(projectionVersion: 2, localItemID: item.id, source: version,
            projectionSHA256: try digest(Projection(item)), appliedAt: date)
        item.quickBooksCatalogReceiptJSON = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
    }
}
