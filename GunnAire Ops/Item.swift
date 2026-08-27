//
//  Item.swift
//  GunnAire Ops
//
//  Created by Eric Gunn on 2/23/26.
//

import Foundation
import SwiftData

enum CatalogItemType: String, Codable, CaseIterable, Identifiable {
    case service = "Service"
    case nonInventory = "NonInventory"

    var id: String { rawValue }
}

enum PricebookReviewStatus: String, Codable, CaseIterable {
    case approved
    case needsReview = "needs_review"
}

/// Immutable pricebook context captured when a customer-facing document is created.
/// The live catalog remains editable; completed estimates and invoices retain the
/// price, cost, tax treatment, and part identity that were actually approved.
struct CatalogLineItemSnapshot: Codable, Equatable, Identifiable {
    let catalogItemID: UUID
    let name: String
    let description: String?
    let sku: String?
    let unitPrice: Double
    let purchaseCost: Double?
    let isTaxable: Bool
    let quantity: Double
    let catalogUpdatedAt: Date

    var id: UUID { catalogItemID }

    init(item: Item, quantity: Double = 1) {
        catalogItemID = item.id
        name = item.name
        description = item.itemDescription
        sku = item.sku
        unitPrice = item.unitPrice
        purchaseCost = item.purchaseCost
        isTaxable = item.isTaxable
        self.quantity = max(quantity, 0.0001)
        catalogUpdatedAt = item.timestamp
    }

    @MainActor static func encoded(from items: [Item], quantities: [UUID: Double] = [:]) -> String? {
        let snapshots = items
            .map { CatalogLineItemSnapshot(item: $0, quantity: quantities[$0.id] ?? 1) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !snapshots.isEmpty,
              let data = try? JSONEncoder().encode(snapshots) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(from json: String?) -> [CatalogLineItemSnapshot] {
        guard let json,
              let data = json.data(using: .utf8),
              let snapshots = try? JSONDecoder().decode([CatalogLineItemSnapshot].self, from: data) else {
            return []
        }
        return snapshots
    }

    private enum CodingKeys: String, CodingKey {
        case catalogItemID, name, description, sku, unitPrice, purchaseCost, isTaxable, quantity, catalogUpdatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        catalogItemID = try values.decode(UUID.self, forKey: .catalogItemID)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        sku = try values.decodeIfPresent(String.self, forKey: .sku)
        unitPrice = try values.decode(Double.self, forKey: .unitPrice)
        purchaseCost = try values.decodeIfPresent(Double.self, forKey: .purchaseCost)
        isTaxable = try values.decode(Bool.self, forKey: .isTaxable)
        quantity = max(try values.decodeIfPresent(Double.self, forKey: .quantity) ?? 1, 0.0001)
        catalogUpdatedAt = try values.decode(Date.self, forKey: .catalogUpdatedAt)
    }
}

@Model
final class Item {
    var id: UUID = UUID()
    var quickBooksID: String?
    /// `pending`, `synced`, or `needs_attention`. This is intentionally stored
    /// with the pricebook item so an offline-created line can be retried after
    /// the originating invoice screen has been dismissed.
    var quickBooksSyncStatus: String = "pending"
    var quickBooksSyncDetail: String?
    var quickBooksLastSyncedAt: Date?
    /// Field-created items remain usable on their originating job, but cannot
    /// become global QBO products/services until an administrator reviews the
    /// price, tax treatment, purchasing identity, and description.
    var pricebookReviewStatusRawValue: String?
    var pricebookCreatedByEmail: String?
    var pricebookReviewedByEmail: String?
    var pricebookReviewedAt: Date?
    var name: String = ""
    var itemTypeRawValue: String = CatalogItemType.service.rawValue
    var unitPrice: Double = 0
    var purchaseCost: Double?
    var isTaxable: Bool = false
    var itemDescription: String?
    var sku: String?
    var preferredVendorName: String?
    var preferredVendorQuickBooksID: String?
    var vendorPartNumber: String?
    var purchaseURL: String?
    var purchaseDescription: String?
    var tracksInventory: Bool = false
    var reorderPoint: Double?
    var defaultInventoryLocation: String?
    var createdAt: Date = Date()
    var timestamp: Date = Date()

    init(
        id: UUID = UUID(),
        quickBooksID: String? = nil,
        quickBooksSyncStatus: String? = nil,
        quickBooksSyncDetail: String? = nil,
        quickBooksLastSyncedAt: Date? = nil,
        pricebookReviewStatus: PricebookReviewStatus = .approved,
        pricebookCreatedByEmail: String? = nil,
        pricebookReviewedByEmail: String? = nil,
        pricebookReviewedAt: Date? = nil,
        name: String,
        itemType: CatalogItemType = .service,
        unitPrice: Double,
        purchaseCost: Double? = nil,
        isTaxable: Bool = false,
        itemDescription: String? = nil,
        sku: String? = nil,
        preferredVendorName: String? = nil,
        preferredVendorQuickBooksID: String? = nil,
        vendorPartNumber: String? = nil,
        purchaseURL: String? = nil,
        purchaseDescription: String? = nil,
        tracksInventory: Bool = false,
        reorderPoint: Double? = nil,
        defaultInventoryLocation: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.quickBooksID = quickBooksID
        self.quickBooksSyncStatus = quickBooksSyncStatus ?? (quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "synced" : "pending")
        self.quickBooksSyncDetail = quickBooksSyncDetail
        self.quickBooksLastSyncedAt = quickBooksLastSyncedAt
        self.pricebookReviewStatusRawValue = pricebookReviewStatus.rawValue
        self.pricebookCreatedByEmail = Self.normalizedOptionalValue(pricebookCreatedByEmail)
        self.pricebookReviewedByEmail = Self.normalizedOptionalValue(pricebookReviewedByEmail)
        self.pricebookReviewedAt = pricebookReviewedAt
        self.name = name
        self.itemTypeRawValue = itemType.rawValue
        self.unitPrice = unitPrice
        self.purchaseCost = purchaseCost
        self.isTaxable = isTaxable
        self.itemDescription = itemDescription
        self.sku = sku
        self.preferredVendorName = preferredVendorName
        self.preferredVendorQuickBooksID = preferredVendorQuickBooksID
        self.vendorPartNumber = vendorPartNumber
        self.purchaseURL = purchaseURL
        self.purchaseDescription = purchaseDescription
        self.tracksInventory = tracksInventory
        self.reorderPoint = reorderPoint
        self.defaultInventoryLocation = defaultInventoryLocation
        self.createdAt = createdAt
        self.timestamp = createdAt
    }

    var itemType: CatalogItemType {
        get { CatalogItemType(rawValue: itemTypeRawValue) ?? .service }
        set { itemTypeRawValue = newValue.rawValue }
    }

    var pricebookReviewStatus: PricebookReviewStatus {
        get {
            guard let pricebookReviewStatusRawValue else { return .approved }
            return PricebookReviewStatus(rawValue: pricebookReviewStatusRawValue) ?? .needsReview
        }
        set { pricebookReviewStatusRawValue = newValue.rawValue }
    }

    var requiresPricebookReview: Bool {
        pricebookReviewStatus == .needsReview
    }

    func markForPricebookReview(createdByEmail: String?) {
        pricebookReviewStatus = .needsReview
        pricebookCreatedByEmail = Self.normalizedOptionalValue(createdByEmail)
        pricebookReviewedByEmail = nil
        pricebookReviewedAt = nil
        quickBooksSyncStatus = "needs_review"
        quickBooksSyncDetail = "Administrator pricebook review is required before QuickBooks publication."
    }

    func approveForPricebook(by reviewerEmail: String?, at date: Date = Date()) {
        pricebookReviewStatus = .approved
        pricebookReviewedByEmail = Self.normalizedOptionalValue(reviewerEmail)
        pricebookReviewedAt = date
        if quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            quickBooksSyncStatus = "pending"
            quickBooksSyncDetail = "Pricebook review approved; QuickBooks publication is pending."
        }
    }

    var needsQuickBooksAttention: Bool {
        quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
        quickBooksSyncStatus == "needs_attention"
    }

    var quickBooksCatalogSyncState: String {
        if quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "synced"
        }
        return quickBooksSyncStatus
    }

    /// Finds the one local catalog record that can safely be reconciled with a
    /// QuickBooks import. A QuickBooks ID is authoritative. Before an item has
    /// one, a unique normalized name is acceptable only when two populated SKUs
    /// agree; this keeps similarly named vendor parts from being merged silently.
    static func matchingLocalCatalogItem(
        in items: [Item],
        quickBooksID: String,
        name: String,
        sku: String?
    ) -> Item? {
        let normalizedQuickBooksID = normalizedCatalogValue(quickBooksID)
        guard !normalizedQuickBooksID.isEmpty else { return nil }

        if let identifiedItem = items.first(where: {
            normalizedCatalogValue($0.quickBooksID ?? "") == normalizedQuickBooksID
        }) {
            return identifiedItem
        }

        let normalizedName = normalizedCatalogValue(name)
        guard !normalizedName.isEmpty else { return nil }
        let candidates = items.filter {
            normalizedCatalogValue($0.name) == normalizedName &&
            normalizedCatalogValuesAreCompatible($0.sku, sku)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func normalizedCatalogValuesAreCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = normalizedCatalogValue(lhs ?? "")
        let right = normalizedCatalogValue(rhs ?? "")
        return left.isEmpty || right.isEmpty || left == right
    }

    private static func normalizedCatalogValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedOptionalValue(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else { return nil }
        return normalized
    }
}
