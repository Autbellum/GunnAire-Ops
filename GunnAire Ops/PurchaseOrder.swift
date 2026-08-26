import Foundation
import SwiftData

enum PurchaseOrderStatus: String, Codable, CaseIterable, Identifiable {
    case draft
    case ordered
    case received
    case cancelled

    var id: String { rawValue }

    var displayName: String { rawValue.capitalized }
}

/// A locally durable purchase request/order. Supplier and QuickBooks credentials stay on
/// approved server-side connectors; this record preserves the job-cost decision trail.
@Model
final class PurchaseOrder {
    var id: UUID = UUID()
    var number: String = ""
    var vendorName: String = ""
    var vendorQuickBooksID: String?
    var serviceCallID: UUID?
    var itemName: String = ""
    var itemSKU: String?
    var vendorPartNumber: String?
    var quantity: Double = 0
    var unitCost: Double = 0
    var shippingCost: Double = 0
    var statusRaw: String = PurchaseOrderStatus.draft.rawValue
    var notes: String?
    var createdByEmail: String?
    var orderedAt: Date?
    var receivedAt: Date?
    var receivedToLocation: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        number: String = PurchaseOrder.nextNumber(),
        vendorName: String,
        vendorQuickBooksID: String? = nil,
        serviceCallID: UUID? = nil,
        itemName: String,
        itemSKU: String? = nil,
        vendorPartNumber: String? = nil,
        quantity: Double,
        unitCost: Double,
        shippingCost: Double = 0,
        status: PurchaseOrderStatus = .draft,
        notes: String? = nil,
        createdByEmail: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.number = number
        self.vendorName = vendorName
        self.vendorQuickBooksID = vendorQuickBooksID
        self.serviceCallID = serviceCallID
        self.itemName = itemName
        self.itemSKU = itemSKU
        self.vendorPartNumber = vendorPartNumber
        self.quantity = quantity
        self.unitCost = unitCost
        self.shippingCost = shippingCost
        self.statusRaw = status.rawValue
        self.notes = notes
        self.createdByEmail = createdByEmail
        self.orderedAt = nil
        self.receivedAt = nil
        self.receivedToLocation = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var status: PurchaseOrderStatus {
        get { PurchaseOrderStatus(rawValue: statusRaw) ?? .draft }
        set {
            statusRaw = newValue.rawValue
            updatedAt = Date()
            switch newValue {
            case .ordered:
                orderedAt = orderedAt ?? updatedAt
            case .received:
                receivedAt = receivedAt ?? updatedAt
            case .draft, .cancelled:
                break
            }
        }
    }

    var total: Double { max(quantity, 0) * max(unitCost, 0) + max(shippingCost, 0) }

    /// A shareable, non-authoritative ordering summary for an approved supplier
    /// channel. It contains no supplier credentials and never transmits an order.
    var supplierOrderSummary: String {
        var lines = [
            "GunnAire Ops purchase order \(number)",
            "Vendor: \(vendorName)",
            "Part: \(itemName)",
            "Quantity: \(quantity.formatted())",
            "Expected unit cost: \(unitCost.formatted(.currency(code: "USD")))",
            "Expected total: \(total.formatted(.currency(code: "USD")))"
        ]
        if let vendorPartNumber, !vendorPartNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Supplier part #: \(vendorPartNumber)")
        }
        if let itemSKU, !itemSKU.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Internal SKU: \(itemSKU)")
        }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Notes: \(notes)")
        }
        return lines.joined(separator: "\n")
    }

    static func nextNumber(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "PO-\(formatter.string(from: now))-\(String(UUID().uuidString.prefix(4)))"
    }
}

enum PurchaseOrderReceiving {
    /// Marks an order received and creates exactly one stock receipt only when
    /// the PO matches an inventory-tracked pricebook item. Direct-ship and
    /// untracked purchases retain their procurement history without inflating
    /// warehouse or truck stock.
    static func receive(
        _ order: PurchaseOrder,
        catalogItems: [Item],
        actorEmail: String?
    ) -> InventoryMovement? {
        guard order.status != .received else { return nil }
        order.status = .received
        guard let item = matchedItem(for: order, catalogItems: catalogItems), item.tracksInventory else {
            return nil
        }
        let configuredLocation = item.defaultInventoryLocation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = configuredLocation.isEmpty ? "Warehouse" : configuredLocation
        order.receivedToLocation = location
        return InventoryMovement(
            item: item,
            type: .receive,
            quantity: order.quantity,
            destinationLocation: location,
            serviceCallID: order.serviceCallID,
            notes: "Received from \(order.vendorName) on \(order.number).",
            createdByEmail: actorEmail
        )
    }

    static func matchedItem(for order: PurchaseOrder, catalogItems: [Item]) -> Item? {
        let sku = order.itemSKU?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sku, !sku.isEmpty,
           let item = catalogItems.first(where: { $0.sku?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(sku) == .orderedSame }) {
            return item
        }
        return catalogItems.first { item in
            item.name.caseInsensitiveCompare(order.itemName) == .orderedSame &&
                item.vendorPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(order.vendorPartNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == .orderedSame
        }
    }
}
