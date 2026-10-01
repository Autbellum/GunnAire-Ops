import Foundation
import SwiftData

nonisolated enum CustomerAccountLinkWorkflowError: LocalizedError {
    case invalidAccountID
    case conflictingLocalCustomer

    var errorDescription: String? {
        switch self {
        case .invalidAccountID: "The customer signup has an invalid identity."
        case .conflictingLocalCustomer: "A different customer already uses this signup identity. Review the customer before linking."
        }
    }
}

/// The server creates account IDs as UUIDs. Reusing that UUID for a new local
/// customer makes retries refer to one identity even after a lost HTTP reply.
nonisolated enum CustomerAccountLinkIdentity {
    static func customerID(for accountID: String) throws -> UUID {
        guard let id = UUID(uuidString: accountID) else {
            throw CustomerAccountLinkWorkflowError.invalidAccountID
        }
        return id
    }

    static func confirmsLink(
        status: String, linkedCustomerID: String?, linkedQuickBooksID: String?, customerID: UUID
    ) -> Bool {
        status == "linked"
            && linkedCustomerID.flatMap(UUID.init(uuidString:)) == customerID
            && linkedQuickBooksID == nil
    }
}

nonisolated enum CustomerAccountLinkResolution: Equatable {
    case confirmed
    case discardUnlinked
    case keepForRetry
    case reviewExistingLink

    static func decide(
        status: String?, linkedCustomerID: String?, linkedQuickBooksID: String?,
        customerID: UUID, definitiveRejection: Bool
    ) -> Self {
        guard let status else { return .keepForRetry }
        if CustomerAccountLinkIdentity.confirmsLink(
            status: status, linkedCustomerID: linkedCustomerID,
            linkedQuickBooksID: linkedQuickBooksID, customerID: customerID
        ) {
            return .confirmed
        }
        if status == "linked" {
            guard let linkedID = linkedCustomerID.flatMap(UUID.init(uuidString:)) else {
                return .reviewExistingLink
            }
            return linkedID == customerID ? .reviewExistingLink : .discardUnlinked
        }
        if status == "pending" && definitiveRejection {
            return .discardUnlinked
        }
        return .keepForRetry
    }
}

/// Owns short SwiftData transactions on a serial utility queue. Models and
/// ModelContext never cross the queue boundary into SwiftUI's main actor.
nonisolated final class CustomerAccountLocalCustomerStore: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "com.gunnaire.customer-account-link", qos: .utility)
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    func prepare(id: UUID, name: String, email: String, phone: String?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    let context = ModelContext(self.container)
                    context.autosaveEnabled = false
                    let existing = try context.fetch(FetchDescriptor<Customer>(predicate: #Predicate { $0.id == id }))
                    if let customer = existing.first {
                        guard existing.count == 1,
                              customer.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                              customer.quickBooksID == nil else {
                            throw CustomerAccountLinkWorkflowError.conflictingLocalCustomer
                        }
                    } else {
                        context.insert(Customer(id: id, name: name, phone: phone, email: email))
                        try context.save()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Remove only an untouched provisional record after the server has
    /// definitively rejected the link and a fresh status read still says pending.
    func discardUnlinked(id: UUID, name: String, email: String, phone: String?) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    let context = ModelContext(self.container)
                    context.autosaveEnabled = false
                    let matches = try context.fetch(FetchDescriptor<Customer>(predicate: #Predicate { $0.id == id }))
                    guard matches.count == 1, let customer = matches.first,
                          customer.name == name, customer.email == email, customer.phone == phone,
                          customer.quickBooksID == nil, customer.serviceCalls.isEmpty,
                          customer.invoices.isEmpty, customer.estimates.isEmpty,
                          customer.recurringContracts.isEmpty, customer.communications.isEmpty,
                          customer.documentAttachments.isEmpty, customer.equipmentProfiles.isEmpty,
                          customer.serviceLocations.isEmpty else {
                        continuation.resume(returning: false)
                        return
                    }
                    context.delete(customer)
                    try context.save()
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
