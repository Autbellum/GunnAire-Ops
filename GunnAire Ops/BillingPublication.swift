import Foundation

enum BillingPublicationError: LocalizedError, Equatable {
    case unavailable, accessRequired, reviewRequired, invalidProposal, invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: "The shared billing service could not confirm this request. Keep the original draft for recovery; no direct QuickBooks retry was sent."
        case .accessRequired: "Confirm your current business and job billing access. Your saved field work is retained."
        case .reviewRequired: "Review the original billing attempt or job assignment before sending another request. Keep the prices already sold."
        case .invalidProposal: "Review the original billing lines, dates, addresses and job assignment."
        case .invalidResponse: "The service did not confirm the original business, job or billing identity. Keep the saved draft for review."
        }
    }
}

enum BillingPublicationDocumentKind: String, Codable { case invoice = "Invoice", estimate = "Estimate" }
enum BillingPublicationOperation: String, Codable { case create, update }
enum BillingPublicationState: String, Codable { case reserved, sending, unknown, confirmed, cancelled }

struct BillingDocumentScope: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let documentType: BillingPublicationDocumentKind
    let localDocumentID: UUID

    func validate(_ workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) throws {
        try workflow.check()
        guard companyID == workflow.companyID, realmID == workflow.realmID, !realmID.isEmpty,
              environment == workflow.environment, ["sandbox", "production"].contains(environment) else {
            throw BillingPublicationError.accessRequired
        }
    }

    var query: [URLQueryItem] {
        [.init(name: "companyID", value: companyID.uuidString.lowercased()), .init(name: "realmID", value: realmID),
         .init(name: "environment", value: environment), .init(name: "documentType", value: documentType.rawValue),
         .init(name: "localDocumentID", value: localDocumentID.uuidString.lowercased())]
    }
}

/// Complete, explicitly reviewed address fields. A free-form local address is
/// never guessed into a tax jurisdiction or silently made nontaxable.
struct BillingPublicationAddress: Codable, Equatable {
    var Line1: String
    var City: String
    var CountrySubDivisionCode: String
    var PostalCode: String
    var Country: String = "US"

    var isComplete: Bool {
        [Line1, City, CountrySubDivisionCode, PostalCode, Country].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct BillingPublicationProposal: Codable {
    let CustomerRef: QuickBooksReference
    let Line: [QuickBooksLineItem]
    let TxnDate: String
    var DueDate: String?
    var PrivateNote: String?
    var BillEmail: QuickBooksEmailAddress?
    var ShipAddr: BillingPublicationAddress?
    var ShipFromAddr: BillingPublicationAddress?
    var ApplyTaxAfterDiscount: Bool?
    var CurrencyRef: QuickBooksReference = .init(value: "USD", name: nil)
    var Id: String?
    var SyncToken: String?
    var sparse: Bool?

    static func userNote(_ value: String?) -> String? {
        guard let value else { return nil }
        let note = value.components(separatedBy: .newlines).filter { line in
            let line = line.trimmingCharacters(in: .whitespaces).lowercased()
            return !["gunnaire invoice id:", "gunnaire estimate id:", "gunnaire publication:"].contains { line.hasPrefix($0) }
        }.joined(separator: "\n")
        return note.isEmpty ? nil : note
    }
}

struct BillingPublicationRequest: Encodable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let documentType: BillingPublicationDocumentKind
    let localDocumentID: UUID
    let localCustomerID: UUID
    let operation: BillingPublicationOperation
    let document: BillingPublicationProposal
    var serviceCallID: UUID?
    var assignmentRevision: Int?

    var scope: BillingDocumentScope {
        .init(companyID: companyID, realmID: realmID, environment: environment,
              documentType: documentType, localDocumentID: localDocumentID)
    }

    func validate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = QuickBooksDateOnly.date(from: document.TxnDate, calendar: calendar)
        guard (serviceCallID == nil) == (assignmentRevision == nil),
              assignmentRevision.map({ (1...2_147_483_647).contains($0) }) ?? true,
              !document.CustomerRef.value.isEmpty, !document.Line.isEmpty, document.Line.count <= 750,
              document.CurrencyRef.value == "USD", document.TxnDate.count == 10,
              date.map({ QuickBooksDateOnly.string(from: $0, calendar: calendar) == document.TxnDate }) == true,
              documentType != .estimate || (operation == .create && document.DueDate == nil),
              operation == .create ? (document.Id == nil && document.SyncToken == nil && document.sparse == nil)
                : (document.Id?.isEmpty == false && document.SyncToken?.isEmpty == false && document.sparse == true) else {
            throw BillingPublicationError.invalidProposal
        }
        if document.Line.contains(where: { $0.SalesItemLineDetail.TaxCodeRef?.value == "TAX" }) {
            guard document.ShipAddr?.isComplete == true, document.ShipFromAddr?.isComplete == true else {
                throw BillingPublicationError.invalidProposal
            }
        }
        guard document.Line.allSatisfy({ $0.hasExplicitAmount && $0.Amount.isFinite && $0.Amount >= 0 }) else {
            throw BillingPublicationError.invalidProposal
        }
    }
}

struct BillingPublicationRecord: Decodable, Identifiable {
    let id: UUID
    let companyID: UUID
    let realmID: String
    let environment: String
    let documentType: BillingPublicationDocumentKind
    let localDocumentID: UUID
    let localCustomerID: UUID
    let operation: BillingPublicationOperation
    let state: BillingPublicationState
    let providerID: String?
    let updatedAt: String

    func validate(_ scope: BillingDocumentScope, customerID: UUID) throws {
        guard companyID == scope.companyID, realmID == scope.realmID, environment == scope.environment,
              documentType == scope.documentType, localDocumentID == scope.localDocumentID, localCustomerID == customerID,
              documentType != .estimate || operation == .create,
              state == .confirmed ? providerID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false : providerID == nil else {
            throw BillingPublicationError.invalidResponse
        }
    }
}

struct BillingPublicationResponse: Decodable {
    let publication: BillingPublicationRecord
    let invoice: QuickBooksInvoice?
    let estimate: QuickBooksEstimate?

    private enum CodingKeys: String, CodingKey { case publication, document }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        publication = try values.decode(BillingPublicationRecord.self, forKey: .publication)
        switch publication.documentType {
        case .invoice: invoice = try values.decode(QuickBooksInvoice.self, forKey: .document); estimate = nil
        case .estimate: estimate = try values.decode(QuickBooksEstimate.self, forKey: .document); invoice = nil
        }
    }

    func validate(_ scope: BillingDocumentScope, customerID: UUID, providerCustomerID: String) throws {
        try publication.validate(scope, customerID: customerID)
        let id = invoice?.Id ?? estimate?.Id
        let customer = invoice?.CustomerRef.value ?? estimate?.CustomerRef.value
        let note = invoice?.PrivateNote ?? estimate?.PrivateNote ?? ""
        let total = invoice?.TotalAmt ?? estimate?.TotalAmt
        let tax = invoice?.TxnTaxDetail?.TotalTax ?? estimate?.TxnTaxDetail?.TotalTax
        guard publication.state == .confirmed, id == publication.providerID, customer == providerCustomerID,
              let total, total.isFinite, total >= 0, let tax, tax.isFinite, tax >= 0, tax <= total,
              note.components(separatedBy: .newlines).contains("GunnAire \(scope.documentType.rawValue) ID: \(scope.localDocumentID.uuidString.uppercased())") else {
            throw BillingPublicationError.invalidResponse
        }
        guard let lines = invoice?.Line ?? estimate?.Line, !lines.isEmpty, lines.count <= 750,
              let totalMoney = Self.money(total), let taxMoney = Self.money(tax) else {
            throw BillingPublicationError.invalidResponse
        }
        var sold = Decimal.zero
        for line in lines {
            guard line.hasExplicitAmount, let amount = Self.money(line.Amount),
                  ["SalesItemLineDetail", "DiscountLineDetail"].contains(line.DetailType) else {
                throw BillingPublicationError.invalidResponse
            }
            sold += line.DetailType == "DiscountLineDetail" ? -amount : amount
        }
        guard sold >= 0, sold + taxMoney == totalMoney else { throw BillingPublicationError.invalidResponse }
        if let invoice {
            guard let balance = invoice.Balance, balance.isFinite, balance >= 0, balance <= total else {
                throw BillingPublicationError.invalidResponse
            }
        }
    }

    private static func money(_ value: Double) -> Decimal? {
        guard value.isFinite, value >= 0, value <= 99_999_999_999,
              var number = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &number, 2, .plain)
        return number == rounded ? number : nil
    }
}

struct BillingPublicationPage: Decodable {
    let publications: [BillingPublicationRecord]
    let nextCursor: String?
}

struct JobBillingScope: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let serviceCallID: UUID

    func validate(_ workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) throws {
        try BillingDocumentScope(companyID: companyID, realmID: realmID, environment: environment,
                                 documentType: .invoice, localDocumentID: serviceCallID).validate(workflow)
    }
}

struct JobBillingAssignment: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let serviceCallID: UUID
    let localCustomerID: UUID
    let revision: Int
    let technicianEmails: [String]
    let enabled: Bool
    let usable: Bool
    let updatedAt: String

    func validate(_ scope: JobBillingScope, customerID: UUID) throws {
        guard companyID == scope.companyID, realmID == scope.realmID, environment == scope.environment,
              serviceCallID == scope.serviceCallID, localCustomerID == customerID, (1...2_147_483_647).contains(revision),
              technicianEmails.count <= 32, Set(technicianEmails).count == technicianEmails.count,
              technicianEmails.allSatisfy({ !$0.isEmpty && $0 == AppAccess.normalizedEmail($0) }),
              !enabled || !technicianEmails.isEmpty, enabled || !usable else { throw BillingPublicationError.invalidResponse }
    }
}

struct JobBillingAssignmentSnapshot: Codable, Equatable {
    let assignment: JobBillingAssignment?
    let connectionRevision: String

    static func validConnectionRevision(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func validate(_ scope: JobBillingScope, customerID: UUID) throws {
        guard Self.validConnectionRevision(connectionRevision) else { throw BillingPublicationError.invalidResponse }
        try assignment?.validate(scope, customerID: customerID)
    }
}

struct JobBillingAssignmentRequest: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let serviceCallID: UUID
    let localCustomerID: UUID
    let technicianEmails: [String]
    let enabled: Bool
    let expectedRevision: Int
    let operationID: UUID
    let connectionRevision: String

    var scope: JobBillingScope { .init(companyID: companyID, realmID: realmID, environment: environment, serviceCallID: serviceCallID) }
}

/// The typed native boundary for the server migration. Every operation requires
/// its original workflow and validates the exact returned identities. No direct
/// accounting fallback or automatic POST retry exists here. The current billing
/// buttons are migrated separately once address/legacy-mapping handoffs exist.
@MainActor
struct BillingPublicationClient {
    typealias Transport = (_ path: String, _ method: String, _ body: Data?) async throws -> Data
    let transport: Transport

    private struct PublicationEnvelope: Decodable { let publication: BillingPublicationRecord }
    private struct ApprovalEnvelope: Decodable { let id: UUID }
    private struct ApprovalRequest: Encodable { let proposal: BillingPublicationRequest; let technicianEmail: String }
    private struct RevocationEnvelope: Decodable { let id: UUID; let revoked: Bool }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw BillingPublicationError.invalidProposal }
    }

    private func perform<T: Decodable>(_ type: T.Type, path: String, body: Data? = nil,
                                      workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> T {
        try workflow.check()
        do {
            return try await workflow.perform { operation in
                let data: Data
                if let body {
                    data = try await operation.performExternalMutation { try await transport(path, "POST", body) }
                } else { data = try await transport(path, "GET", nil) }
                try workflow.check()
                return try JSONDecoder().decode(type, from: data)
            }
        } catch {
            try workflow.check()
            if let error = error as? BillingPublicationError { throw error }
            if error is DecodingError { throw BillingPublicationError.invalidResponse }
            if case GunnAireBackendError.server(let status, _) = error {
                if status == 400 { throw BillingPublicationError.invalidProposal }
                if status == 401 || status == 403 { throw BillingPublicationError.accessRequired }
                if status == 409 { throw BillingPublicationError.reviewRequired }
            }
            throw BillingPublicationError.unavailable
        }
    }

    private func path(_ base: String, _ query: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.path = base; components.queryItems = query
        return components.string ?? base
    }

    func publish(_ request: BillingPublicationRequest, workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> BillingPublicationResponse {
        try request.scope.validate(workflow); try request.validate()
        let result = try await perform(BillingPublicationResponse.self, path: "/api/billing-publications",
                                       body: encode(request), workflow: workflow)
        try result.validate(request.scope, customerID: request.localCustomerID, providerCustomerID: request.document.CustomerRef.value)
        guard result.publication.operation == request.operation,
              QuickBooksBillingLineEvidence.matches(expected: request.document.Line, reported: result.invoice?.Line ?? result.estimate?.Line),
              (result.invoice?.TxnDate ?? result.estimate?.TxnDate) == request.document.TxnDate,
              request.document.DueDate == nil || result.invoice?.DueDate == request.document.DueDate,
              request.document.Id == nil || request.document.Id == result.publication.providerID else {
            throw BillingPublicationError.invalidResponse
        }
        return result
    }

    func list(_ scope: BillingDocumentScope, customerID: UUID, cursor: String? = nil,
              workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> BillingPublicationPage {
        try scope.validate(workflow)
        var query = scope.query
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        let result = try await perform(BillingPublicationPage.self, path: path("/api/billing-publications", query), workflow: workflow)
        guard result.publications.count <= 50, Set(result.publications.map(\.id)).count == result.publications.count,
              result.nextCursor.map({ !$0.isEmpty && $0.count <= 2048 && $0 != cursor }) ?? true else { throw BillingPublicationError.invalidResponse }
        for row in result.publications { try row.validate(scope, customerID: customerID) }
        return result
    }

    func recover(_ id: UUID, scope: BillingDocumentScope, customerID: UUID, providerCustomerID: String,
                 workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> BillingPublicationResponse {
        try scope.validate(workflow)
        let result = try await perform(BillingPublicationResponse.self, path: "/api/billing-publications/\(id.uuidString.lowercased())/recover",
                                       body: Data("{}".utf8), workflow: workflow)
        try result.validate(scope, customerID: customerID, providerCustomerID: providerCustomerID)
        guard result.publication.id == id else { throw BillingPublicationError.invalidResponse }
        return result
    }

    func cancel(_ id: UUID, scope: BillingDocumentScope, customerID: UUID,
                workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> BillingPublicationRecord {
        try scope.validate(workflow)
        let result = try await perform(PublicationEnvelope.self, path: "/api/billing-publications/\(id.uuidString.lowercased())/cancel",
                                       body: Data("{}".utf8), workflow: workflow).publication
        try result.validate(scope, customerID: customerID)
        guard result.id == id, result.state == .cancelled else { throw BillingPublicationError.invalidResponse }
        return result
    }

    func approve(_ request: BillingPublicationRequest, technicianEmail: String,
                 workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> UUID {
        try request.scope.validate(workflow); try request.validate()
        return try await perform(ApprovalEnvelope.self, path: "/api/billing-publications/approve",
            body: encode(ApprovalRequest(proposal: request, technicianEmail: technicianEmail)), workflow: workflow).id
    }

    func revokeApproval(_ id: UUID, workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws {
        let result = try await perform(RevocationEnvelope.self,
            path: "/api/billing-publications/draft-grants/\(id.uuidString.lowercased())/revoke", body: Data("{}".utf8), workflow: workflow)
        guard result.id == id, result.revoked else { throw BillingPublicationError.invalidResponse }
    }

    func assignment(_ scope: JobBillingScope, customerID: UUID,
                    workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> JobBillingAssignment? {
        try await assignmentSnapshot(scope, customerID: customerID, workflow: workflow).assignment
    }

    func assignmentSnapshot(_ scope: JobBillingScope, customerID: UUID,
                            workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> JobBillingAssignmentSnapshot {
        try scope.validate(workflow)
        let query = [URLQueryItem(name: "companyID", value: scope.companyID.uuidString.lowercased()), .init(name: "realmID", value: scope.realmID),
                     .init(name: "environment", value: scope.environment), .init(name: "serviceCallID", value: scope.serviceCallID.uuidString.lowercased())]
        let result = try await perform(JobBillingAssignmentSnapshot.self, path: path("/api/job-billing-assignments", query), workflow: workflow)
        try result.validate(scope, customerID: customerID)
        return result
    }

    func saveAssignment(_ request: JobBillingAssignmentRequest, workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> JobBillingAssignment {
        try request.scope.validate(workflow)
        guard (0..<2_147_483_647).contains(request.expectedRevision),
              JobBillingAssignmentSnapshot.validConnectionRevision(request.connectionRevision) else { throw BillingPublicationError.invalidProposal }
        let envelope = try await perform(JobBillingAssignmentSnapshot.self, path: "/api/job-billing-assignments",
                                        body: encode(request), workflow: workflow)
        guard envelope.connectionRevision == request.connectionRevision, let result = envelope.assignment else { throw BillingPublicationError.invalidResponse }
        try result.validate(request.scope, customerID: request.localCustomerID)
        guard result.revision == request.expectedRevision + 1, result.enabled == request.enabled,
              !request.enabled || result.usable, result.technicianEmails.sorted() == request.technicianEmails.sorted() else {
            throw BillingPublicationError.invalidResponse
        }
        return result
    }
}
