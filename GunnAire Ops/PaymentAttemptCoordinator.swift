import Foundation

/// Only opaque identities and cents cross the business-server boundary.
/// Card/bank details and single-use tokens never enter this journal.
struct PaymentAttemptIntent: Codable, Equatable {
    let id: UUID
    let companyID: UUID
    let realmID: String
    let environment: String
    let invoiceID: UUID
    let invoiceQuickBooksID: String
    let customerQuickBooksID: String
    let amountCents: Int
    let rail: String
    let kind: String
    var sourcePaymentID: UUID? = nil
    var sourceProviderID: String? = nil
    var sourceAccountingID: String? = nil

    var clientTransactionID: String { "ga-\(kind)-\(id.uuidString.lowercased())" }
}

struct PaymentAttemptRecord: Decodable, Identifiable {
    enum State: String, Decodable {
        case reserved, sending, unknown, confirmed, completed, cancelled, declined
    }
    let intent: PaymentAttemptIntent
    let requestID: UUID
    let clientTransactionID: String
    let state: State
    let providerID: String?
    let candidateProviderID: String?
    let providerStatus: String?
    let accountingID: String?
    var id: UUID { intent.id }

    private enum CodingKeys: String, CodingKey {
        case requestID, clientTransactionID, state, providerID, candidateProviderID, providerStatus, accountingID
    }

    init(from decoder: Decoder) throws {
        intent = try PaymentAttemptIntent(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        clientTransactionID = try values.decode(String.self, forKey: .clientTransactionID)
        state = try values.decode(State.self, forKey: .state)
        providerID = try values.decodeIfPresent(String.self, forKey: .providerID)
        candidateProviderID = try values.decodeIfPresent(String.self, forKey: .candidateProviderID)
        providerStatus = try values.decodeIfPresent(String.self, forKey: .providerStatus)
        accountingID = try values.decodeIfPresent(String.self, forKey: .accountingID)
    }

    func validate(for expected: PaymentAttemptIntent, states: Set<State>, previous: Self? = nil) throws {
        guard intent == expected, clientTransactionID == expected.clientTransactionID,
              states.contains(state), previous == nil || previous?.requestID == requestID else {
            throw PaymentAttemptError.needsReview
        }
        if state == .confirmed || state == .completed {
            guard let providerID, Self.isReference(providerID), providerStatus != nil else {
                throw PaymentAttemptError.needsReview
            }
        }
        if state == .completed {
            guard let accountingID, Self.isReference(accountingID) else { throw PaymentAttemptError.needsReview }
        }
    }

    static func isReference(_ value: String) -> Bool {
        QuickBooksProviderReference.isValid(value)
    }
}

enum PaymentAttemptError: Error, LocalizedError, Equatable {
    case unavailable, needsReview, originalAccountingRequired
    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The business server could not verify payment coordination. Check your connection and sign-in before collecting. No new payment was authorized here."
        case .needsReview:
            "This invoice has an unfinished or unconfirmed payment attempt. Review the original transaction before collecting again; do not re-enter a charge."
        case .originalAccountingRequired:
            "Finish the original payment's QuickBooks accounting follow-up before issuing a refund."
        }
    }
}

@MainActor
protocol PaymentAttemptCoordinating {
    func companyID() throws -> UUID
    func reserve(_ intent: PaymentAttemptIntent) async throws -> PaymentAttemptRecord
    func action(_ action: String, attemptID: UUID, reference: String?) async throws -> PaymentAttemptRecord
    func get(_ id: UUID) async throws -> PaymentAttemptRecord
    func list(invoiceID: UUID) async throws -> [PaymentAttemptRecord]
}

struct BackendPaymentAttemptCoordinator: PaymentAttemptCoordinating {
    func companyID() throws -> UUID {
        guard let id = CompanyWorkspaceAccessController.shared.verifiedCompanyID else {
            throw WorkspaceProviderAccessError.unavailable
        }
        return id
    }
    func reserve(_ intent: PaymentAttemptIntent) async throws -> PaymentAttemptRecord {
        try await GunnAireBackendService.reservePaymentAttempt(intent)
    }
    func action(_ action: String, attemptID: UUID, reference: String?) async throws -> PaymentAttemptRecord {
        try await GunnAireBackendService.updatePaymentAttempt(attemptID, action: action, reference: reference)
    }
    func get(_ id: UUID) async throws -> PaymentAttemptRecord {
        try await GunnAireBackendService.fetchPaymentAttempt(id)
    }
    func list(invoiceID: UUID) async throws -> [PaymentAttemptRecord] {
        try await GunnAireBackendService.fetchPaymentAttempts(companyID: companyID(), invoiceID: invoiceID)
    }
}

/// The begin response is a one-time permit, never an idempotent resend ticket.
/// Lost responses and cancellation after begin retain the server hold.
struct PaymentAttemptDispatcher {
    let journal: any PaymentAttemptCoordinating
    let check: () throws -> Void

    func dispatch<Preparation, Response>(
        intent: PaymentAttemptIntent,
        prepare: () async throws -> Preparation,
        send: (Preparation, PaymentAttemptRecord) async throws -> Response,
        providerID: (Response) -> String
    ) async throws -> (Response, PaymentAttemptRecord) {
        try check()
        let reservation = try await journal.reserve(intent)
        try check()
        try reservation.validate(for: intent, states: [.reserved])
        var began = false
        do {
            let prepared = try await prepare()
            try check()
            // Even a lost begin response can have committed the permit.
            began = true
            let permit = try await journal.action("begin", attemptID: intent.id, reference: nil)
            try check()
            try permit.validate(for: intent, states: [.sending], previous: reservation)
            let response = try await send(prepared, permit)
            try check()
            let id = providerID(response)
            guard PaymentAttemptRecord.isReference(id) else { throw PaymentAttemptError.needsReview }
            let confirmed = try await journal.action("confirm", attemptID: intent.id, reference: id)
            try check()
            try confirmed.validate(for: intent, states: [.confirmed, .completed], previous: permit)
            guard confirmed.providerID == id else { throw PaymentAttemptError.needsReview }
            return (response, confirmed)
        } catch {
            // Never write an old attempt using a replacement workspace/session.
            if (try? check()) != nil {
                _ = try? await journal.action(began ? "unknown" : "cancel", attemptID: intent.id, reference: nil)
            }
            try check()
            if began { throw PaymentAttemptError.needsReview }
            throw error
        }
    }
}
