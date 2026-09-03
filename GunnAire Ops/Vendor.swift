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
    case carrierEnterprise
    case genericCatalog

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .johnstoneDirectConnect: "Johnstone Supply DirectConnect"
        case .johnstonePunchOut: "Johnstone Supply Punch-out"
        case .lennoxPartner: "Lennox Partner"
        case .carrierEnterprise: "Carrier Enterprise Procurement"
        case .genericCatalog: "Generic Supplier Catalog"
        }
    }

    /// Public vendor documentation does not establish self-service API access for these
    /// commercial connectors. Keep them disabled until contract/onboarding is complete.
    var requiresSupplierOnboarding: Bool { self != .genericCatalog }
}

enum SupplierConnectorContract {
    static let currentVersion = 2
}

struct SupplierConnectorReadiness: Codable, Identifiable, Equatable {
    let contractVersion: Int
    let kind: SupplierConnectorKind
    let displayName: String
    let provider: String
    let status: String
    let detail: String
    let capabilities: [String]
    let canSubmitOrders: Bool
    let onboardingURL: String?

    var id: SupplierConnectorKind { kind }

    var isReady: Bool {
        contractVersion == SupplierConnectorContract.currentVersion &&
            capabilities.contains("purchaseOrders") &&
            canSubmitOrders &&
            status.caseInsensitiveCompare("ready") == .orderedSame
    }

    var statusLabel: String {
        if canSubmitOrders && contractVersion != SupplierConnectorContract.currentVersion {
            return "Connector upgrade required"
        }
        return switch status {
        case "ready": "Ready"
        case "onboardingRequired": "Onboarding required"
        case "partnerGated": "Partner approval required"
        case "thirdPartyOnly": "Third-party only"
        case "adapterRequired": "Server adapter required"
        default: "Unavailable"
        }
    }
}

enum SupplierConnectorSelectionPolicy {
    static func orderableConnectors(
        from connectors: [SupplierConnectorReadiness]
    ) -> [SupplierConnectorReadiness] {
        connectors
            .filter(\.isReady)
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
                return lhs.displayName < rhs.displayName
            }
    }

    static func preferredConnectorKind(
        for vendorName: String,
        from connectors: [SupplierConnectorReadiness]
    ) -> SupplierConnectorKind? {
        orderableConnectors(for: vendorName, from: connectors).first?.kind
    }

    static func orderableConnectors(
        for vendorName: String,
        from connectors: [SupplierConnectorReadiness]
    ) -> [SupplierConnectorReadiness] {
        let normalizedVendor = vendorName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ready = orderableConnectors(from: connectors)
        if normalizedVendor.contains("johnstone") {
            return ready.filter { connector in
                connector.kind == .johnstoneDirectConnect || connector.kind == .johnstonePunchOut
            }
        }
        if normalizedVendor.contains("lennox") {
            return ready.filter { $0.kind == .lennoxPartner }
        }
        if normalizedVendor.contains("carrier") {
            return ready.filter { $0.kind == .carrierEnterprise }
        }
        let providerMatches = ready.filter {
            normalizedVendor.contains($0.provider.lowercased()) ||
                $0.provider.lowercased().contains(normalizedVendor)
        }
        return providerMatches.isEmpty
            ? ready.filter { $0.kind == .genericCatalog }
            : providerMatches
    }
}

struct SupplierConnectorAcceptedLine: Equatable {
    let lineID: UUID
    let supplierPartNumber: String?
    let confirmedQuantity: Double
    let confirmedUnitCost: Double
}

struct SupplierConnectorOrderAcceptance: Equatable {
    let contractVersion: Int
    let purchaseOrderID: UUID
    let purchaseOrderNumber: String
    let connectorKind: SupplierConnectorKind
    let externalOrderID: String
    let reference: String
    let supplierLocation: String?
    let confirmedLines: [SupplierConnectorAcceptedLine]
    let confirmedShippingCost: Double
    let currencyCode: String
    let confirmedByEmail: String
    let confirmedAt: Date
    let priceAvailabilityCheckedAt: Date
    let idempotencyKey: String
    let replayed: Bool

    var confirmedUnitCost: Double {
        confirmedLines.first?.confirmedUnitCost ?? .nan
    }
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
