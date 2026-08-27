import Foundation
import SwiftData

/// A reusable physical property where field work is performed. The customer
/// address remains the billing/default address used by QuickBooks; jobs retain
/// both this stable ID and their own address snapshot for offline history.
@Model
final class CustomerServiceLocation {
    var id: UUID = UUID()
    var customer: Customer?
    var name: String = ""
    var address: String = ""
    var contactName: String?
    var contactPhone: String?
    var accessNotes: String?
    var isPrimary: Bool = false
    var isActive: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        customer: Customer? = nil,
        name: String,
        address: String,
        contactName: String? = nil,
        contactPhone: String? = nil,
        accessNotes: String? = nil,
        isPrimary: Bool = false,
        isActive: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.customer = customer
        self.name = name
        self.address = address
        self.contactName = contactName
        self.contactPhone = contactPhone
        self.accessNotes = accessNotes
        self.isPrimary = isPrimary
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
    }

    var contactSummary: String? {
        [contactName, contactPhone]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " • ")
            .nilIfEmpty
    }
}

enum CustomerServiceLocationPolicy {
    static func locations(for customerID: UUID, in locations: [CustomerServiceLocation], includeInactive: Bool = false) -> [CustomerServiceLocation] {
        locations
            .filter { $0.customer?.id == customerID && (includeInactive || $0.isActive) }
            .sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary && !rhs.isPrimary }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    static func preferredLocation(for customerID: UUID, in locations: [CustomerServiceLocation]) -> CustomerServiceLocation? {
        let active = self.locations(for: customerID, in: locations)
        return active.first(where: \.isPrimary) ?? active.first
    }

    static func location(
        id: UUID?,
        customerID: UUID,
        in locations: [CustomerServiceLocation],
        includeInactive: Bool = false
    ) -> CustomerServiceLocation? {
        guard let id else { return nil }
        return locations.first {
            $0.id == id && $0.customer?.id == customerID && (includeInactive || $0.isActive)
        }
    }

    static func matchingLocation(address: String?, customerID: UUID, in locations: [CustomerServiceLocation]) -> CustomerServiceLocation? {
        guard let normalizedAddress = normalized(address) else { return nil }
        return self.locations(for: customerID, in: locations)
            .first { normalized($0.address) == normalizedAddress }
    }

    static func setPrimary(_ location: CustomerServiceLocation, among locations: [CustomerServiceLocation], now: Date = Date()) {
        guard let customerID = location.customer?.id else { return }
        for candidate in locations where candidate.customer?.id == customerID {
            candidate.isPrimary = candidate.id == location.id
        }
        location.isActive = true
        location.updatedAt = now
    }

    static func resolvedAddress(locationID: UUID?, customer: Customer, locations: [CustomerServiceLocation], fallbackSnapshot: String? = nil) -> String? {
        if let location = location(id: locationID, customerID: customer.id, in: locations) {
            return location.address
        }
        if let snapshot = normalizedDisplay(fallbackSnapshot) { return snapshot }
        if let preferred = preferredLocation(for: customer.id, in: locations) { return preferred.address }
        return normalizedDisplay(customer.address)
    }

    private static func normalized(_ value: String?) -> String? {
        normalizedDisplay(value)?.lowercased()
    }

    private static func normalizedDisplay(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
