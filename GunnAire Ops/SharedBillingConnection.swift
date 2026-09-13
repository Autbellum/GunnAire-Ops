import Foundation
import SwiftData

enum BillingPublicationTransportPolicy {
    static func allows(path: String, method: String, bodyBytes: Int?) -> Bool {
        guard let endpoint = URLComponents(string: path), endpoint.scheme == nil, endpoint.host == nil,
              endpoint.fragment == nil, path.utf8.count <= 8192,
              (bodyBytes ?? 0) >= 0, (bodyBytes ?? 0) <= 1024 * 1024 else { return false }
        let base = "/api/billing-publications"
        let assignments = endpoint.path == "/api/job-billing-assignments"
        if endpoint.path == "/api/job-billing-assignments/connection" { return method == "GET" && bodyBytes == nil }
        guard assignments || endpoint.path == base || endpoint.path.hasPrefix(base + "/") else { return false }
        let suffix = String(endpoint.path.dropFirst(base.count))
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
        func exactID(_ index: Int) -> Bool {
            parts.indices.contains(index) && UUID(uuidString: String(parts[index])).map { $0.uuidString.lowercased() == parts[index] } == true
        }
        if method == "GET", bodyBytes == nil {
            return assignments || suffix.isEmpty || ["/context", "/connection"].contains(suffix) ||
                (endpoint.query == nil && parts.count == 2 && exactID(1))
        }
        guard method == "POST", bodyBytes != nil, endpoint.query == nil else { return false }
        return assignments || suffix.isEmpty || suffix == "/approve" ||
            (parts.count == 3 && exactID(1) && ["recover", "cancel", "approve"].contains(String(parts[2]))) ||
            (parts.count == 4 && parts[1] == "draft-grants" && exactID(2) && parts[3] == "revoke")
    }
}

enum SharedBillingConnectionError: LocalizedError, Equatable {
    case unavailable, updateRequired, invalid
    var errorDescription: String? {
        switch self {
        case .unavailable: "Your document is saved. The business connection could not be checked. Try Sync Saved Document when online; ask the office if it still cannot connect."
        case .updateRequired: "Your document is saved. Ask the administrator to update the business server before syncing it."
        case .invalid: "The service did not confirm this saved document's business connection. Reopen Billing Review; your saved work is retained."
        }
    }
}

struct SharedBillingIdentity: Codable, Equatable {
    let companyID: UUID
    let documentType: BillingPublicationDocumentKind
    let localDocumentID: UUID
    let localCustomerID: UUID
    let serviceCallID: UUID?
    let projectMilestoneID: UUID?

    var path: String {
        var query = ["companyID": companyID.uuidString.lowercased(), "documentType": documentType.rawValue,
                     "localDocumentID": localDocumentID.uuidString.lowercased(), "localCustomerID": localCustomerID.uuidString.lowercased()]
        if let serviceCallID { query["serviceCallID"] = serviceCallID.uuidString.lowercased() }
        if let projectMilestoneID { query["projectMilestoneID"] = projectMilestoneID.uuidString.lowercased() }
        var parts = URLComponents()
        parts.path = "/api/billing-publications/connection"
        parts.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        return parts.string!
    }
}

struct SharedBillingConnection: Decodable {
    let identity: SharedBillingIdentity
    let realmID: String
    let environment: String
    let connectionRevision: String
    let protocolVersion: Int

    private enum CodingKeys: String, CodingKey { case realmID, environment, connectionRevision, protocolVersion }
    init(from decoder: Decoder) throws {
        identity = try SharedBillingIdentity(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        realmID = try values.decode(String.self, forKey: .realmID)
        environment = try values.decode(String.self, forKey: .environment)
        connectionRevision = try values.decode(String.self, forKey: .connectionRevision)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
    }
    func validate(_ expected: SharedBillingIdentity) throws {
        guard protocolVersion == 1, identity == expected, PaymentAttemptRecord.isReference(realmID),
              ["sandbox", "production"].contains(environment),
              JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision) else {
            throw SharedBillingConnectionError.invalid
        }
    }
}

/// Capture before scheduling work. Discovery cannot adopt changed drafts, items,
/// payments, jobs, users or workspaces. The resulting workflow owns its normal
/// mutation-aware checks; this preflight never rebases a saved document.
@MainActor
final class SharedBillingPreparation {
    private let document: QuickBooksBillingDocument
    private let context: ModelContext
    private let identity: SharedBillingIdentity
    private let operation: WorkspaceProviderOperation
    private let validateOriginal: () throws -> Void
    private let validateAccess: () throws -> Void
    private let client: BillingPublicationClient
    private let catalog: CatalogPublicationBoundary.Transport
    private let customer: CustomerPublicationBoundary.Transport

    init(document: QuickBooksBillingDocument, context: ModelContext,
         isCurrent: @escaping () -> Bool,
         validateAccess: (() throws -> Void)? = nil,
         client: BillingPublicationClient? = nil,
         catalog: CatalogPublicationBoundary.Transport? = nil,
         customer: CustomerPublicationBoundary.Transport? = nil,
         fixtureCompanyID: UUID? = nil) throws {
        if fixtureCompanyID != nil { precondition(GunnAireCloudKit.usesTestDatabase) }
        let access = validateAccess ?? { try QuickBooksBillingAccessPolicy.validate(context: context, document: document) }
        try access()
        guard let companyID = fixtureCompanyID ?? CompanyWorkspaceAccessController.shared.verifiedCompanyID,
              let originalCustomer = document.customer else { throw BillingPublicationError.accessRequired }
        self.document = document; self.context = context; self.validateAccess = access
        identity = .init(companyID: companyID, documentType: document.label == "Invoice" ? .invoice : .estimate,
            localDocumentID: document.id, localCustomerID: originalCustomer.id,
            serviceCallID: document.serviceCallID, projectMilestoneID: document.projectMilestoneID)
        self.client = client ?? GunnAireBackendService.billingPublicationClient
        self.catalog = catalog ?? GunnAireBackendService.publishCatalog
        self.customer = customer ?? GunnAireBackendService.publishCustomer
        operation = try WorkspaceProviderOperation.capture {
            guard isCurrent() else { return false }
            do { try access(); return true } catch { return false }
        }
        let checkDocument = document.validation(context: context)
        let draft = QuickBooksCustomerCreateOperation.draft(for: originalCustomer)
        let customerID = originalCustomer.quickBooksID
        let selected = Set(CatalogLineItemSnapshot.decoded(from: document.snapshotJSON)
            .flatMap { [$0.catalogItemID] + $0.soldLeaves.map(\.catalogItemID) })
        func items() throws -> [ObjectIdentifier: QuickBooksCatalogItemRevision] {
            Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Item>())
                .filter { selected.contains($0.id) }.map { (ObjectIdentifier($0), QuickBooksCatalogItemRevision($0)) })
        }
        func payments() throws -> [QuickBooksBillingPaymentRevision] {
            try context.fetch(FetchDescriptor<Payment>()).filter { $0.invoice?.id == document.id }
                .sorted { $0.id.uuidString < $1.id.uuidString }.map(QuickBooksBillingPaymentRevision.init)
        }
        let savedItems = try items(), savedPayments = try payments()
        validateOriginal = {
            try checkDocument()
            let customers = try context.fetch(FetchDescriptor<Customer>()).filter { $0.id == draft.localCustomerID }
            guard customers.count == 1, customers.first === originalCustomer,
                  QuickBooksCustomerCreateOperation.draft(for: originalCustomer) == draft,
                  originalCustomer.quickBooksID == customerID,
                  try items() == savedItems, try payments() == savedPayments else {
                throw QuickBooksBillingWorkflowError.changed
            }
        }
        try validateOriginal()
    }

    func makeWorkflow(lifecycle: QuickBooksSyncLifecycle,
                      billingJournal: BillingNativeJournalStore? = nil) async throws -> QuickBooksBillingWorkflow {
        try operation.check(); try validateOriginal()
        let connection: SharedBillingConnection
        do {
            let data = try await client.transport(identity.path, "GET", nil)
            try operation.check(); try validateOriginal()
            guard data.count <= 16_384 else { throw SharedBillingConnectionError.invalid }
            connection = try JSONDecoder().decode(SharedBillingConnection.self, from: data)
            try connection.validate(identity)
        } catch {
            try operation.check(); try validateOriginal()
            if let error = error as? SharedBillingConnectionError { throw error }
            if error is DecodingError { throw SharedBillingConnectionError.invalid }
            if case GunnAireBackendError.server(let status, _) = error {
                if status == 404 { throw SharedBillingConnectionError.updateRequired }
                if status == 401 || status == 403 { throw BillingPublicationError.accessRequired }
                if status == 409 { throw BillingPublicationError.reviewRequired }
            }
            throw SharedBillingConnectionError.unavailable
        }
        let api = QuickBooksDataAPI(sharedBilling: connection, operation: operation,
            billingPublisher: client, catalogPublisher: catalog, customerPublisher: customer)
        return try QuickBooksBillingWorkflow(document: document, context: context, api: api,
            lifecycle: lifecycle, validateAccess: validateAccess, billingJournal: billingJournal)
    }
}
