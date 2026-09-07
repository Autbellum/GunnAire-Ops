import Foundation
import SwiftData

enum QuickBooksLinkReviewError: LocalizedError, Equatable {
    case access, changed, invalid, unavailable, storage
    var errorDescription: String? {
        switch self {
        case .access: "Current administrator access to the original business and QuickBooks connection is required."
        case .changed: "A saved record, connection or reviewed QuickBooks value changed. Recover the original review, then cancel it and review the current links."
        case .invalid: "The original records and review identities could not be verified. No replacement accounting record was created."
        case .unavailable: "The shared service could not confirm the review. Recover its saved status before another decision."
        case .storage: "This device could not retain the original link review. Existing work was not cleared."
        }
    }
}

enum QuickBooksLinkKind: String, Codable, CaseIterable, Identifiable {
    case customer = "Customer", item = "Item", invoice = "Invoice", estimate = "Estimate"
    var id: String { rawValue }
    var plural: String { switch self { case .customer: "Customers"; case .item: "Items"; case .invoice: "Invoices"; case .estimate: "Estimates" } }
    var document: Bool { self == .invoice || self == .estimate }
}

struct QuickBooksExistingLink: Codable, Equatable, Identifiable {
    let kind: QuickBooksLinkKind
    let localID: UUID
    let providerID: String
    let localName: String
    var localCustomerID: UUID?
    var serviceCallID: UUID?
    var id: String { kind.rawValue + ":" + localID.uuidString }
    func validate() throws {
        guard providerID.range(of: #"^[A-Za-z0-9._:-]{1,128}$"#, options: .regularExpression) != nil,
              !localName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, localName.count <= 500,
              !localName.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              kind.document ? localCustomerID != nil : (localCustomerID == nil && serviceCallID == nil) else {
            throw QuickBooksLinkReviewError.invalid
        }
    }
}

struct QuickBooksLinkReviewRequest: Codable, Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let operationID: UUID
    let connectionRevision: String
    let links: [QuickBooksExistingLink]
    func validate() throws {
        guard (1...25).contains(links.count), Set(links.map(\.id)).count == links.count,
              Set(links.map { $0.kind.rawValue + ":" + $0.providerID }).count == links.count,
              JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision) else { throw QuickBooksLinkReviewError.invalid }
        for link in links { try link.validate() }
    }
}

struct QuickBooksLinkEvidence: Codable, Equatable {
    let Id: String
    let SyncToken: String
    var DisplayName: String?
    var Name: String?
    var Active: Bool?
    var itemType: String?
    var UnitPrice: Double?
    var Taxable: Bool?
    var DocNumber: String?
    var TotalAmt: Double?
    var Balance: Double?
    var CustomerRef: QuickBooksReference?
    private enum CodingKeys: String, CodingKey {
        case Id, SyncToken, DisplayName, Name, Active, UnitPrice, Taxable, DocNumber, TotalAmt, Balance, CustomerRef
        case itemType = "Type"
    }
    var title: String { DisplayName ?? Name ?? DocNumber ?? "Existing accounting document" }
    static func == (left: Self, right: Self) -> Bool {
        left.Id == right.Id && left.SyncToken == right.SyncToken && left.DisplayName == right.DisplayName &&
        left.Name == right.Name && left.Active == right.Active && left.itemType == right.itemType && left.UnitPrice == right.UnitPrice &&
        left.Taxable == right.Taxable && left.DocNumber == right.DocNumber && left.TotalAmt == right.TotalAmt &&
        left.Balance == right.Balance && left.CustomerRef?.value == right.CustomerRef?.value
    }
}

struct QuickBooksLinkReviewRecord: Codable, Identifiable {
    enum State: String, Codable { case review, confirmed, cancelled }
    struct Entry: Codable, Identifiable {
        let kind: QuickBooksLinkKind
        let localID: UUID
        let providerID: String
        let localName: String
        var localCustomerID: UUID?
        var serviceCallID: UUID?
        let quickBooks: QuickBooksLinkEvidence
        var link: QuickBooksExistingLink { .init(kind: kind, localID: localID, providerID: providerID, localName: localName, localCustomerID: localCustomerID, serviceCallID: serviceCallID) }
        var id: String { link.id }
    }
    let id: UUID
    let companyID: UUID
    let realmID: String
    let environment: String
    let operationID: UUID
    let revision: String
    let state: State
    let expiresAt: String
    let links: [Entry]

    var expiry: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: expiresAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: expiresAt)
    }

    func validate(_ request: QuickBooksLinkReviewRequest) throws {
        try request.validate()
        guard companyID == request.companyID, realmID == request.realmID, environment == request.environment,
              operationID == request.operationID, JobBillingAssignmentSnapshot.validConnectionRevision(revision), expiry != nil,
              links.map(\.link).sorted(by: { $0.id < $1.id }) == request.links.sorted(by: { $0.id < $1.id }) else {
            throw QuickBooksLinkReviewError.invalid
        }
        for entry in links {
            let value = entry.quickBooks
            guard value.Id == entry.providerID, !value.SyncToken.isEmpty, !value.title.isEmpty,
                  value.UnitPrice.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw QuickBooksLinkReviewError.invalid }
            if entry.kind.document {
                guard let total = value.TotalAmt, total.isFinite, total >= 0, value.CustomerRef?.value.isEmpty == false,
                      entry.kind != .invoice || value.Balance.map({ $0.isFinite && $0 >= 0 && $0 <= total }) == true else {
                    throw QuickBooksLinkReviewError.invalid
                }
            } else if value.Active == nil { throw QuickBooksLinkReviewError.invalid }
        }
    }
}

@MainActor struct QuickBooksLinkReviewClient {
    let transport: (String, String, Data?) async throws -> Data
    struct Lookup: Decodable { let connectionRevision: String; let review: QuickBooksLinkReviewRecord? }

    private func perform<T: Decodable>(_ type: T.Type, path: String, body: Data? = nil,
                                      workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> T {
        do {
            return try await workflow.perform { operation in
                let data: Data
                if let body { data = try await operation.performExternalMutation { try await transport(path, "POST", body) } }
                else { data = try await transport(path, "GET", nil) }
                try workflow.check()
                return try JSONDecoder().decode(type, from: data)
            }
        } catch {
            try workflow.check()
            if let error = error as? QuickBooksLinkReviewError { throw error }
            if error is DecodingError { throw QuickBooksLinkReviewError.invalid }
            if case GunnAireBackendError.server(let status, _) = error {
                if [401, 403].contains(status) { throw QuickBooksLinkReviewError.access }
                if status == 409 { throw QuickBooksLinkReviewError.changed }
                if status == 400 { throw QuickBooksLinkReviewError.invalid }
            }
            throw QuickBooksLinkReviewError.unavailable
        }
    }

    private func validate(_ request: QuickBooksLinkReviewRequest, _ workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) throws {
        try request.validate(); try workflow.check()
        guard request.companyID == workflow.companyID, request.realmID == workflow.realmID,
              request.environment == workflow.environment else { throw QuickBooksLinkReviewError.access }
    }

    func lookup(operationID: UUID? = nil, workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> Lookup {
        guard let companyID = workflow.companyID, let realmID = workflow.realmID, !realmID.isEmpty else { throw QuickBooksLinkReviewError.access }
        var components = URLComponents(); components.path = "/api/qbo-link-reviews"
        components.queryItems = [.init(name: "companyID", value: companyID.uuidString), .init(name: "realmID", value: realmID), .init(name: "environment", value: workflow.environment)]
        if let operationID { components.queryItems?.append(.init(name: "operationID", value: operationID.uuidString)) }
        let result = try await perform(Lookup.self, path: components.string!, workflow: workflow)
        guard JobBillingAssignmentSnapshot.validConnectionRevision(result.connectionRevision),
              result.review == nil || (result.review?.operationID == operationID && result.review?.companyID == companyID &&
              result.review?.realmID == realmID && result.review?.environment == workflow.environment) else { throw QuickBooksLinkReviewError.invalid }
        return result
    }

    func preview(_ request: QuickBooksLinkReviewRequest, workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> QuickBooksLinkReviewRecord {
        try validate(request, workflow)
        let result = try await perform(QuickBooksLinkReviewRecord.self, path: "/api/qbo-link-reviews", body: JSONEncoder().encode(request), workflow: workflow)
        try result.validate(request)
        return result
    }

    func decide(_ record: QuickBooksLinkReviewRecord, request: QuickBooksLinkReviewRequest, confirm: Bool,
                workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow) async throws -> QuickBooksLinkReviewRecord {
        try validate(request, workflow); try record.validate(request)
        let result = try await perform(QuickBooksLinkReviewRecord.self,
            path: "/api/qbo-link-reviews/\(record.id.uuidString.lowercased())/\(confirm ? "confirm" : "cancel")",
            body: JSONEncoder().encode(["revision": record.revision]), workflow: workflow)
        try result.validate(request)
        guard result.id == record.id, result.revision == record.revision,
              result.state == (confirm ? .confirmed : .cancelled), result.links.map(\.quickBooks) == record.links.map(\.quickBooks) else {
            throw QuickBooksLinkReviewError.invalid
        }
        return result
    }
}

/// Only the original request is retained locally. Provider evidence and the
/// decision stay on the shared server. Keychain writes complete before POST.
struct QuickBooksLinkReviewStore {
    var read: (JobBillingQueueScope) throws -> QuickBooksLinkReviewRequest?
    var write: (JobBillingQueueScope, QuickBooksLinkReviewRequest?) throws -> Void
    static let device = Self(read: { scope in
        do { return try KeychainStore.loadCodable(QuickBooksLinkReviewRequest.self, account: "QBOLinkReview-v1-" + scope.storageKey) }
        catch { throw QuickBooksLinkReviewError.storage }
    }, write: { scope, request in
        do {
            let account = "QBOLinkReview-v1-" + scope.storageKey
            if let request { try KeychainStore.saveCodable(request, account: account) }
            else { try KeychainStore.remove(account: account) }
        } catch { throw QuickBooksLinkReviewError.storage }
    })
}

@MainActor final class QuickBooksLinkReviewOwner {
    let workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow
    let scope: JobBillingQueueScope
    private let context: ModelContext
    private let access: () throws -> Void
    private let client: QuickBooksLinkReviewClient
    private let store: QuickBooksLinkReviewStore
    private let lifetime: QuickBooksSyncLifecycle
    private var busy = false
    private(set) var request: QuickBooksLinkReviewRequest?
    private(set) var record: QuickBooksLinkReviewRecord?
    private(set) var decisionNeedsRecovery = false
    private(set) var connectionChanged = false

    init(context: ModelContext, api: QuickBooksDataAPI, client: QuickBooksLinkReviewClient, store: QuickBooksLinkReviewStore? = nil,
         actorEmail: String? = nil, validateAccess: (() throws -> Void)? = nil) throws {
        let validate = validateAccess ?? { try QuickBooksSyncAccessPolicy.validate(context: context) }
        let expectedActor = AppAccess.normalizedEmail(actorEmail ?? AppIdentity.currentEmail)
        let access = {
            try validate()
            guard AppAccess.normalizedEmail(actorEmail ?? AppIdentity.currentEmail) == expectedActor else {
                throw QuickBooksLinkReviewError.access
            }
        }
        try access()
        let lifetime = QuickBooksSyncLifecycle()
        workflow = try lifetime.begin(api: api, validateAccess: access).workflow
        guard let company = workflow.companyID, let realm = workflow.realmID else { throw QuickBooksLinkReviewError.access }
        scope = .init(companyID: company, realmID: realm, environment: workflow.environment, actorEmail: expectedActor)
        try scope.validate()
        let store = store ?? .device
        self.context = context; self.client = client; self.store = store; self.access = access; self.lifetime = lifetime
        request = try store.read(scope)
        if let request {
            try request.validate()
            guard request.companyID == company, request.realmID == realm, request.environment == scope.environment else { throw QuickBooksLinkReviewError.storage }
        }
    }

    func cancel() { lifetime.cancel() }
    func check() throws { try workflow.check(); try access() }

    func candidates() throws -> [QuickBooksExistingLink] {
        try check()
        let customers = try context.fetch(FetchDescriptor<Customer>())
        var values = customers.compactMap { value -> QuickBooksExistingLink? in
            guard let id = QuickBooksBillingIdentity.identifier(value.quickBooksID) else { return nil }
            return .init(kind: .customer, localID: value.id, providerID: id, localName: value.name)
        }
        values += try context.fetch(FetchDescriptor<Item>()).compactMap { value in
            QuickBooksBillingIdentity.identifier(value.quickBooksID).map { .init(kind: .item, localID: value.id, providerID: $0, localName: value.name) }
        }
        for invoice in try context.fetch(FetchDescriptor<Invoice>()) {
            guard let id = QuickBooksBillingIdentity.identifier(invoice.quickBooksID), let customer = invoice.customer else { continue }
            values.append(.init(kind: .invoice, localID: invoice.id, providerID: id, localName: customer.name + " — invoice " + invoice.createdAt.formatted(date: .numeric, time: .omitted), localCustomerID: customer.id, serviceCallID: invoice.serviceCallID))
        }
        for estimate in try context.fetch(FetchDescriptor<Estimate>()) {
            guard let id = QuickBooksBillingIdentity.identifier(estimate.quickBooksID), let customer = estimate.customer else { continue }
            values.append(.init(kind: .estimate, localID: estimate.id, providerID: id, localName: customer.name + " — estimate " + estimate.createdAt.formatted(date: .numeric, time: .omitted), localCustomerID: customer.id, serviceCallID: estimate.serviceCallID))
        }
        guard Set(values.map(\.id)).count == values.count,
              Set(values.map { $0.kind.rawValue + ":" + $0.providerID }).count == values.count else { throw QuickBooksLinkReviewError.changed }
        return values.sorted { $0.localName.localizedStandardCompare($1.localName) == .orderedAscending }
    }

    func batch(_ selected: Set<String>) throws -> [QuickBooksExistingLink] {
        let available = try candidates()
        var links = available.filter { selected.contains($0.id) }
        guard !links.isEmpty, links.count == selected.count else { throw QuickBooksLinkReviewError.changed }
        for customerID in Set(links.compactMap(\.localCustomerID)) {
            guard let customer = available.first(where: { $0.kind == .customer && $0.localID == customerID }) else { throw QuickBooksLinkReviewError.changed }
            if !links.contains(where: { $0.id == customer.id }) { links.append(customer) }
        }
        guard links.count <= 25 else { throw QuickBooksLinkReviewError.invalid }
        return links
    }

    private func validateLocal(_ request: QuickBooksLinkReviewRequest) throws {
        let available = try candidates()
        guard request.links.allSatisfy({ available.contains($0) }) else { throw QuickBooksLinkReviewError.changed }
    }

    func recover() async throws {
        guard !busy else { throw QuickBooksBillingWorkflowError.busy }
        busy = true; defer { busy = false }
        try check()
        guard let request else { return }
        let lookup = try await client.lookup(operationID: request.operationID, workflow: workflow)
        try check()
        try lookup.review?.validate(request)
        record = lookup.review
        connectionChanged = lookup.connectionRevision != request.connectionRevision
        decisionNeedsRecovery = false
    }

    func preview(selected: Set<String>) async throws {
        guard !busy else { throw QuickBooksBillingWorkflowError.busy }
        busy = true; defer { busy = false }
        try check()
        guard !connectionChanged else { throw QuickBooksLinkReviewError.changed }
        if request == nil {
            let links = try batch(selected)
            let lookup = try await client.lookup(workflow: workflow)
            try check()
            let value = QuickBooksLinkReviewRequest(companyID: scope.companyID, realmID: scope.realmID, environment: scope.environment,
                operationID: UUID(), connectionRevision: lookup.connectionRevision, links: links)
            try value.validate(); try validateLocal(value)
            try store.write(scope, value); request = value
        }
        guard let request else { throw QuickBooksLinkReviewError.storage }
        try validateLocal(request)
        let result = try await client.preview(request, workflow: workflow)
        try check(); try validateLocal(request)
        record = result
    }

    func decide(confirm: Bool) async throws {
        guard !busy else { throw QuickBooksBillingWorkflowError.busy }
        busy = true; defer { busy = false }
        try check()
        guard !decisionNeedsRecovery else { throw QuickBooksLinkReviewError.unavailable }
        guard let request, let record, record.state == .review else { throw QuickBooksLinkReviewError.invalid }
        if confirm {
            guard !connectionChanged else { throw QuickBooksLinkReviewError.changed }
            try validateLocal(request)
        }
        decisionNeedsRecovery = true
        let result = try await client.decide(record, request: request, confirm: confirm, workflow: workflow)
        try check()
        self.record = result // No local model, line, price or accounting-status write.
        decisionNeedsRecovery = false
    }

    func nextBatch() throws {
        try check()
        guard !busy, let record, record.state != .review else { throw QuickBooksLinkReviewError.changed }
        try store.write(scope, nil); request = nil; self.record = nil
        connectionChanged = false; decisionNeedsRecovery = false
    }

    /// A current scoped GET proved this old-grant operation has no server review.
    /// Old-grant previews cannot subsequently commit after their final grant check.
    func retireUnsubmittedRequest() throws {
        try check()
        guard !busy, request != nil, record == nil, connectionChanged, !decisionNeedsRecovery else {
            throw QuickBooksLinkReviewError.changed
        }
        try store.write(scope, nil); request = nil; connectionChanged = false
    }
}
