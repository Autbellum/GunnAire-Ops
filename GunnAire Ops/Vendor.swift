// Vendor.swift
// Model for vendors
import Foundation
import SwiftData

@Model
final class Vendor {
    var id: UUID = UUID()
    var quickBooksID: String?
    var name: String = ""
    var contactInfo: String?
    
    init(id: UUID = UUID(), quickBooksID: String? = nil, name: String, contactInfo: String? = nil) {
        self.id = id
        self.quickBooksID = quickBooksID
        self.name = name
        self.contactInfo = contactInfo
    }
}

/// A supplier connection is deliberately modeled separately from the accounting vendor.
/// It becomes active only after the supplier has approved the business account and issued
/// the required credentials or punch-out/DirectConnect configuration.
enum SupplierConnectorKind: String, Codable, CaseIterable, Identifiable {
    case johnstoneDirectConnect
    case johnstonePunchOut
    case lennoxPartner
    case genericCatalog

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .johnstoneDirectConnect: "Johnstone Supply DirectConnect"
        case .johnstonePunchOut: "Johnstone Supply Punch-out"
        case .lennoxPartner: "Lennox Partner"
        case .genericCatalog: "Generic Supplier Catalog"
        }
    }

    /// Public vendor documentation does not establish self-service API access for these
    /// commercial connectors. Keep them disabled until contract/onboarding is complete.
    var requiresSupplierOnboarding: Bool { self != .genericCatalog }
}

struct SupplierCatalogQuery: Codable, Equatable {
    let searchTerm: String
    let branchID: String?
    let customerAccountID: String?
}

struct SupplierCatalogItem: Codable, Identifiable, Equatable {
    let id: String
    let supplierSKU: String
    let manufacturerPartNumber: String?
    let name: String
    let unitOfMeasure: String?
    let price: Decimal?
    let availableQuantity: Decimal?
    let currencyCode: String?
    let lastUpdatedAt: Date?
}

/// Server-side adapters implement this protocol. The iOS client must never carry a
/// supplier secret, account credential, punch-out session, or purchase-order authority.
protocol SupplierConnector {
    var kind: SupplierConnectorKind { get }
    func searchCatalog(_ query: SupplierCatalogQuery) async throws -> [SupplierCatalogItem]
}
