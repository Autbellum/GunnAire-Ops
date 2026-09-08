import Foundation
import SwiftData

enum FieldPaymentReviewError: Error, LocalizedError, Equatable {
    case access, invalid, changed, unavailable, serviceUpdate
    var errorDescription: String? {
        switch self {
        case .access: "Your access or saved invoice changed. Reopen the collection task with your approved business account."
        case .invalid: "QuickBooks did not confirm complete payment details. Ask Accounting to review this invoice before collecting again."
        case .changed: "The invoice or collection details changed during the check. Refresh before collecting again."
        case .unavailable: "The shared payment check is unavailable. Your saved work is unchanged. Reconnect and refresh before collecting again."
        case .serviceUpdate: "Shared payment review needs the current business server. Ask your administrator to update it; do not collect the card again."
        }
    }
    static func safe(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if error is WorkspaceProviderAccessError || error is CompanyWorkspaceFailure { return .access }
        if case GunnAireBackendError.server(let status, _) = error {
            if status == 401 || status == 403 { return .access }
            if status == 404 { return .serviceUpdate }
            if status == 409 { return .changed }
        }
        return .unavailable
    }
}

struct FieldPaymentReviewIdentity: Codable, Equatable {
    let companyID: UUID
    let invoiceID: UUID
    let localCustomerID: UUID
    let invoiceQuickBooksID: String
    let customerQuickBooksID: String
    let serviceCallID: UUID?

    var query: [String: String] {
        var result = ["companyID": companyID.uuidString.lowercased(), "invoiceID": invoiceID.uuidString.lowercased(),
                      "localCustomerID": localCustomerID.uuidString.lowercased(), "invoiceQuickBooksID": invoiceQuickBooksID,
                      "customerQuickBooksID": customerQuickBooksID]
        if let serviceCallID { result["serviceCallID"] = serviceCallID.uuidString.lowercased() }
        return result
    }
    func validate() throws {
        guard PaymentAttemptRecord.isReference(invoiceQuickBooksID), PaymentAttemptRecord.isReference(customerQuickBooksID)
        else { throw FieldPaymentReviewError.invalid }
    }
}

struct FieldPaymentReviewScope: Codable, Equatable {
    let companyID: UUID
    let invoiceID: UUID
    let localCustomerID: UUID
    let invoiceQuickBooksID: String
    let customerQuickBooksID: String
    let serviceCallID: UUID?
    let realmID: String
    let environment: String
    let connectionRevision: String
    var identity: FieldPaymentReviewIdentity {
        .init(companyID: companyID, invoiceID: invoiceID, localCustomerID: localCustomerID,
              invoiceQuickBooksID: invoiceQuickBooksID, customerQuickBooksID: customerQuickBooksID, serviceCallID: serviceCallID)
    }
    var query: [String: String] {
        identity.query.merging(["realmID": realmID, "environment": environment, "connectionRevision": connectionRevision]) { _, new in new }
    }
    func validate(_ expected: FieldPaymentReviewIdentity) throws {
        try identity.validate()
        guard identity == expected, PaymentAttemptRecord.isReference(realmID), ["sandbox", "production"].contains(environment),
              JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision) else { throw FieldPaymentReviewError.invalid }
    }
}

struct FieldPaymentReviewSnapshot: Codable, Equatable {
    struct Allocation: Codable, Equatable {
        let paymentQuickBooksID: String
        let syncToken: String
        let postingDate: String
        let appliedCents: Int
        let includesCreditOrAdjustment: Bool
    }
    let scope: FieldPaymentReviewScope
    let protocolVersion: Int
    let invoiceNumber: String?
    let invoiceDate: String
    let syncToken: String
    let observedAt: String
    let currency: String
    let totalCents: Int
    let balanceCents: Int
    let collectionLimitCents: Int
    let hasOpenAttempt: Bool
    let fundsSettlementVerified: Bool
    let authority: String
    let payments: [Allocation]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, invoiceNumber, invoiceDate, syncToken, observedAt, currency, totalCents, balanceCents
        case collectionLimitCents, hasOpenAttempt, fundsSettlementVerified, authority, payments
    }
    init(from decoder: Decoder) throws {
        scope = try FieldPaymentReviewScope(from: decoder)
        let v = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try v.decode(Int.self, forKey: .protocolVersion)
        invoiceNumber = try v.decodeIfPresent(String.self, forKey: .invoiceNumber)
        invoiceDate = try v.decode(String.self, forKey: .invoiceDate)
        syncToken = try v.decode(String.self, forKey: .syncToken)
        observedAt = try v.decode(String.self, forKey: .observedAt)
        currency = try v.decode(String.self, forKey: .currency)
        totalCents = try v.decode(Int.self, forKey: .totalCents)
        balanceCents = try v.decode(Int.self, forKey: .balanceCents)
        collectionLimitCents = try v.decode(Int.self, forKey: .collectionLimitCents)
        hasOpenAttempt = try v.decode(Bool.self, forKey: .hasOpenAttempt)
        fundsSettlementVerified = try v.decode(Bool.self, forKey: .fundsSettlementVerified)
        authority = try v.decode(String.self, forKey: .authority)
        payments = try v.decode([Allocation].self, forKey: .payments)
    }

    func encode(to encoder: Encoder) throws {
        try scope.encode(to: encoder)
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(protocolVersion, forKey: .protocolVersion)
        try v.encodeIfPresent(invoiceNumber, forKey: .invoiceNumber)
        try v.encode(invoiceDate, forKey: .invoiceDate)
        try v.encode(syncToken, forKey: .syncToken)
        try v.encode(observedAt, forKey: .observedAt)
        try v.encode(currency, forKey: .currency)
        try v.encode(totalCents, forKey: .totalCents)
        try v.encode(balanceCents, forKey: .balanceCents)
        try v.encode(collectionLimitCents, forKey: .collectionLimitCents)
        try v.encode(hasOpenAttempt, forKey: .hasOpenAttempt)
        try v.encode(fundsSettlementVerified, forKey: .fundsSettlementVerified)
        try v.encode(authority, forKey: .authority)
        try v.encode(payments, forKey: .payments)
    }

    func validate(_ expected: FieldPaymentReviewScope, now: Date) throws {
        try scope.validate(expected.identity)
        guard scope == expected, protocolVersion == 1, currency == "USD", !fundsSettlementVerified,
              ["office", "assigned"].contains(authority), (0...100_000_000).contains(totalCents),
              (0...totalCents).contains(balanceCents), (0...balanceCents).contains(collectionLimitCents),
              !hasOpenAttempt || collectionLimitCents == 0,
              PaymentAttemptRecord.isReference(syncToken), Self.validDate(invoiceDate),
              let observed = CompanyWorkspaceClock.parse(observedAt), observed <= now.addingTimeInterval(30),
              observed >= now.addingTimeInterval(-120), payments.count <= 32,
              Set(payments.map(\.paymentQuickBooksID)).count == payments.count else { throw FieldPaymentReviewError.invalid }
        if let invoiceNumber {
            guard !invoiceNumber.isEmpty, invoiceNumber.count <= 21,
                  invoiceNumber == invoiceNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                  !invoiceNumber.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.illegalCharacters.contains($0) })
            else { throw FieldPaymentReviewError.invalid }
        }
        for payment in payments {
            guard PaymentAttemptRecord.isReference(payment.paymentQuickBooksID), PaymentAttemptRecord.isReference(payment.syncToken),
                  Self.validDate(payment.postingDate), (1...100_000_000).contains(payment.appliedCents) else { throw FieldPaymentReviewError.invalid }
        }
        guard payments.reduce(0, { $0 + $1.appliedCents }) <= totalCents - balanceCents else { throw FieldPaymentReviewError.invalid }
    }
    private static func validDate(_ value: String) -> Bool {
        value.count == 10 && QuickBooksDateOnly.date(from: value).map { QuickBooksDateOnly.string(from: $0) == value } == true
    }
}

@MainActor final class FieldPaymentReviewClient {
    typealias Request = (String) async throws -> Data
    static let maximumBytes = 64 * 1024
    let identity: FieldPaymentReviewIdentity
    private let checkAccess: () throws -> Void
    private let transport: Request
    private let now: () -> Date
    init(identity: FieldPaymentReviewIdentity, check: @escaping () throws -> Void,
         request: @escaping Request, now: @escaping () -> Date = Date.init) throws {
        try identity.validate(); try check()
        self.identity = identity; checkAccess = check; transport = request; self.now = now
    }
    func check() throws { try checkAccess(); try Task.checkCancellation() }
    private func request(_ endpoint: String, query: [String: String]) async throws -> Data {
        try check()
        var url = URLComponents(); url.path = endpoint
        url.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        guard let path = url.string else { throw FieldPaymentReviewError.invalid }
        let data = try await transport(path)
        try check()
        guard data.count <= Self.maximumBytes else { throw FieldPaymentReviewError.invalid }
        return data
    }
    func review() async throws -> FieldPaymentReviewSnapshot {
        do {
            let decoder = JSONDecoder()
            let scope = try decoder.decode(FieldPaymentReviewScope.self,
                from: await request("/api/field-payment-review/context", query: identity.query))
            try scope.validate(identity)
            let result = try decoder.decode(FieldPaymentReviewSnapshot.self,
                from: await request("/api/field-payment-review", query: scope.query))
            try check(); try result.validate(scope, now: now())
            return result
        } catch {
            try check()
            if error is DecodingError { throw FieldPaymentReviewError.invalid }
            throw FieldPaymentReviewError.safe(error)
        }
    }

    static func live(invoice: Invoice) throws -> FieldPaymentReviewClient {
        let controller = CompanyWorkspaceAccessController.shared
        guard let stamp = controller.operationStamp, let companyID = controller.verifiedCompanyID,
              let context = invoice.modelContext, context.container === controller.authorizedContainer,
              let customer = invoice.customer, let invoiceID = invoice.quickBooksID, let customerID = customer.quickBooksID,
              let role = controller.verifiedRole, [.admin, .accounting, .fieldTechnician].contains(role)
        else { throw FieldPaymentReviewError.access }
        let identity = FieldPaymentReviewIdentity(companyID: companyID, invoiceID: invoice.id, localCustomerID: customer.id,
            invoiceQuickBooksID: invoiceID, customerQuickBooksID: customerID, serviceCallID: invoice.serviceCallID)
        let modelCheck = QuickBooksBillingDocument.invoice(invoice).validation(context: context)
        let amount = invoice.amount, balance = invoice.quickBooksBalanceDue, status = invoice.status
        let syncedAt = invoice.quickBooksLastSyncedAt, receipt = invoice.quickBooksPaymentReviewJSON
        let paymentDigest = try FieldPaymentReceiptReconciliation.paymentDigest(invoice: invoice, context: context)
        return try .init(identity: identity, check: {
            try modelCheck()
            guard controller.operationStamp == stamp, controller.verifiedRole == role,
                  context.container === controller.authorizedContainer, invoice.modelContext === context,
                  invoice.customer === customer, customer.id == identity.localCustomerID,
                  invoice.quickBooksID == identity.invoiceQuickBooksID, customer.quickBooksID == identity.customerQuickBooksID,
                  invoice.serviceCallID == identity.serviceCallID, invoice.amount == amount,
                  invoice.quickBooksBalanceDue == balance, invoice.status == status,
                  invoice.quickBooksLastSyncedAt == syncedAt, invoice.quickBooksPaymentReviewJSON == receipt,
                  try FieldPaymentReceiptReconciliation.paymentDigest(invoice: invoice, context: context) == paymentDigest
            else { throw FieldPaymentReviewError.access }
        }, request: GunnAireBackendService.fieldPaymentReviewRequest)
    }
}
