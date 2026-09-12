import Foundation

/// Provider IDs are opaque. Display names, invoice numbers, prices and dates
/// never establish ownership of an operational billing record.
enum QuickBooksBillingIdentity {
    static let invoiceReviewState = "identity_conflict"
    static let invoiceReviewMessage = "This invoice has conflicting QuickBooks identity evidence. Review its customer and linked records in QuickBooks Management before changing it or collecting payment. No billing history was removed."

    static func identifier(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func customerMatches(_ customer: Customer?, reference: QuickBooksReference?) -> Bool {
        guard let local = identifier(customer?.quickBooksID),
              let remote = identifier(reference?.value) else { return false }
        return local == remote
    }

    static func sameCustomer(_ lhs: Customer?, _ rhs: Customer?) -> Bool {
        guard let lhs, let rhs, lhs.id == rhs.id else { return false }
        if let first = identifier(lhs.quickBooksID), let second = identifier(rhs.quickBooksID) {
            return first == second
        }
        return true
    }

    static func uniqueCache<T>(_ records: [T], key: (T) -> String?) -> [String: T] {
        let pairs = records.compactMap { record in key(record).map { ($0, record) } }
        return Dictionary(grouping: pairs, by: { $0.0 }).compactMapValues {
            $0.count == 1 ? $0[0].1 : nil
        }
    }

    static func conflictingKeys<T>(_ records: [T], key: (T) -> String?) -> Set<String> {
        Set(Dictionary(grouping: records.compactMap(key), by: { $0 })
            .filter { $0.value.count > 1 }.keys)
    }

    static func hasAmbiguousMapping(_ records: [(id: UUID, customerID: UUID?, providerID: String?)]) -> Bool {
        let localGroups = Dictionary(grouping: records, by: { $0.id })
        if localGroups.values.contains(where: {
            Set($0.map(\.customerID)).count > 1 ||
            Set($0.compactMap { identifier($0.providerID) }).count > 1
        }) { return true }
        let linked = records.filter { identifier($0.providerID) != nil }
        let providerGroups = Dictionary(grouping: linked, by: { identifier($0.providerID)! })
        return providerGroups.values.contains {
            Set($0.map(\.id)).count > 1 || Set($0.map(\.customerID)).count > 1
        }
    }

    static func markForReview(_ invoices: [Invoice]) {
        for invoice in invoices {
            invoice.quickBooksSyncStatus = invoiceReviewState
            invoice.quickBooksSyncDetail = invoiceReviewMessage
        }
    }
}

struct QuickBooksBillingImportReview: LocalizedError {
    let reasons: [String]

    var errorDescription: String? {
        "Safe records were refreshed; some QuickBooks records still need review. " +
        reasons.joined(separator: " ") +
        " No billing records were merged or deleted. Open QuickBooks Management to review the affected mappings before retrying."
    }
}
