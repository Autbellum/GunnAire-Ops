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
                (endpoint.query == nil && parts.count == 2 && exactID(1)) ||
                (endpoint.query == nil && parts.count == 3 && parts[1] == "background-estimate" && exactID(2))
        }
        guard method == "POST", bodyBytes != nil, endpoint.query == nil else { return false }
        return assignments || suffix.isEmpty || suffix == "/approve" || suffix == "/background-estimate" ||
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

nonisolated struct SharedBillingIdentity: Codable, Equatable, Sendable {
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
        return parts.string ?? ""
    }
}

nonisolated struct SharedBillingConnection: Decodable, Sendable {
    let identity: SharedBillingIdentity
    let realmID: String
    let environment: String
    let connectionRevision: String
    let protocolVersion: Int
    let estimateQueueVersion: Int?

    private enum CodingKeys: String, CodingKey { case realmID, environment, connectionRevision, protocolVersion, estimateQueueVersion }
    init(from decoder: Decoder) throws {
        identity = try SharedBillingIdentity(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        realmID = try values.decode(String.self, forKey: .realmID)
        environment = try values.decode(String.self, forKey: .environment)
        connectionRevision = try values.decode(String.self, forKey: .connectionRevision)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        estimateQueueVersion = try values.decodeIfPresent(Int.self, forKey: .estimateQueueVersion)
    }
    static func decodeAsync(_ data: Data) async throws -> Self {
        try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(Self.self, from: data)
        }.value
    }
    func validate(_ expected: SharedBillingIdentity) throws {
        guard protocolVersion == 1, estimateQueueVersion == nil || estimateQueueVersion == 1,
              identity == expected, QuickBooksProviderReference.isValid(realmID),
              ["sandbox", "production"].contains(environment),
              JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision) else {
            throw SharedBillingConnectionError.invalid
        }
    }
}

/// A tap-time snapshot of already-loaded main-context Items. Constructing it
/// never performs a SwiftData fetch; a later preparation may only use these
/// same objects while their immutable business revisions still match.
@MainActor
final class QuickBooksSelectedItemCapture {
    let items: [Item]
    private let documentID: UUID
    private let snapshotJSON: String?
    private let subtotal: Double
    private let revisions: [UUID: QuickBooksCatalogItemRevision]
    private let context: ModelContext
    private let documentFieldsUnchanged: () -> Bool
    private let customer: Customer
    private let customerDraft: QuickBooksCustomerCreateDraft
    private let workspaceStamp: CompanyWorkspaceOperationStamp?
    private let actorEmail: String

    init(document: QuickBooksBillingDocument, items: [Item], context: ModelContext) throws {
        guard case .estimate = document,
              let customer = document.customer else { throw QuickBooksBillingWorkflowError.changed }
        let selected = Self.selectedIDs(document.snapshotJSON)
        guard !selected.isEmpty, selected.count <= 20, items.count == selected.count else {
            throw QuickBooksBillingWorkflowError.changed
        }
        var revisions: [UUID: QuickBooksCatalogItemRevision] = [:]
        for item in items {
            guard selected.contains(item.id), item.modelContext === context, !item.isDeleted,
                  revisions.updateValue(QuickBooksCatalogItemRevision(item), forKey: item.id) == nil else {
                throw QuickBooksBillingWorkflowError.changed
            }
        }
        self.items = items
        documentID = document.id
        snapshotJSON = document.snapshotJSON
        subtotal = document.subtotal
        self.revisions = revisions
        self.context = context
        documentFieldsUnchanged = document.fieldValidation()
        self.customer = customer
        customerDraft = QuickBooksCustomerCreateOperation.draft(for: customer)
        workspaceStamp = CompanyWorkspaceAccessController.shared.operationStamp
        actorEmail = AppAccess.normalizedEmail(AppIdentity.currentEmail)
    }

    func validate(document: QuickBooksBillingDocument, context: ModelContext) throws {
        guard self.context === context, document.id == documentID,
              document.snapshotJSON == snapshotJSON, document.subtotal == subtotal,
              documentFieldsUnchanged(), document.customer === customer,
              QuickBooksCustomerCreateOperation.draft(for: customer) == customerDraft,
              CompanyWorkspaceAccessController.shared.operationStamp == workspaceStamp,
              AppAccess.normalizedEmail(AppIdentity.currentEmail) == actorEmail,
              Self.selectedIDs(document.snapshotJSON) == Set(revisions.keys),
              !(context.changedModelsArray + context.insertedModelsArray + context.deletedModelsArray)
                .contains(where: { ($0 as? Item).map { revisions[$0.id] != nil } == true }),
              items.allSatisfy({ item in
                  item.modelContext === context && !item.isDeleted &&
                  revisions[item.id] == QuickBooksCatalogItemRevision(item)
              }) else { throw QuickBooksBillingWorkflowError.changed }
    }

    private static func selectedIDs(_ snapshotJSON: String?) -> Set<UUID> {
        Set(CatalogLineItemSnapshot.decoded(from: snapshotJSON)
            .flatMap { [$0.catalogItemID] + $0.soldLeaves.map(\.catalogItemID) })
    }
}

/// A saved estimate without a save-time capture needs two deliberate actions:
/// the first pins already-loaded Items, and the second uses only those pins.
/// A changed pin is discarded instead of silently adopting a newer revision.
@MainActor
final class QuickBooksSelectedItemCaptureGate {
    private var pending: (id: UUID, capture: QuickBooksSelectedItemCapture)?

    func takeOrPrepare(document: QuickBooksBillingDocument, context: ModelContext,
                       prepare: () throws -> QuickBooksSelectedItemCapture) throws -> QuickBooksSelectedItemCapture? {
        guard case .estimate = document else { throw QuickBooksBillingWorkflowError.changed }
        if let pending, pending.id == document.id {
            self.pending = nil
            try pending.capture.validate(document: document, context: context)
            return pending.capture
        }
        pending = (document.id, try prepare())
        return nil
    }
}

/// Capture before scheduling work. Discovery cannot adopt changed drafts, items,
/// payments, jobs, users or workspaces. The resulting workflow owns its normal
/// mutation-aware checks; this preflight never rebases a saved document.
@MainActor
final class QuickBooksSelectedItemPreflight {
    var validate: (() async throws -> Void)?

    func check() async throws {
        guard let validate else { throw QuickBooksBillingWorkflowError.changed }
        try await validate()
    }
}

@MainActor
final class SharedBillingPreparation {
    private let document: QuickBooksBillingDocument
    private let context: ModelContext
    private let identity: SharedBillingIdentity
    private let operation: WorkspaceProviderOperation
    private let validateOriginal: () throws -> Void
    private let validateAccess: () throws -> Void
    private let checkAccessOffMain: (() async throws -> Void)?
    private let selectedItemPreflight: QuickBooksSelectedItemPreflight?
    private let capturedItems: [Item]
    private let client: BillingPublicationClient
    private let catalog: CatalogPublicationBoundary.Transport
    private let customer: CustomerPublicationBoundary.Transport

    init(document: QuickBooksBillingDocument, context: ModelContext,
         isCurrent: @escaping () -> Bool,
         validateAccess: (() throws -> Void)? = nil,
         client: BillingPublicationClient? = nil,
         catalog: CatalogPublicationBoundary.Transport? = nil,
         customer: CustomerPublicationBoundary.Transport? = nil,
         fixtureCompanyID: UUID? = nil,
         requiresAdministrator: Bool = false,
         selectedItemCapture: QuickBooksSelectedItemCapture? = nil) throws {
        if fixtureCompanyID != nil { precondition(GunnAireCloudKit.usesTestDatabase) }
        let staffEmail = AppIdentity.currentEmail
        let workspaceStamp = CompanyWorkspaceAccessController.shared.operationStamp
        let offMainAccess: (() async throws -> Void)?
        let access: () throws -> Void
        if requiresAdministrator {
            access = {
                try QuickBooksBillingAccessPolicy.checkLocalFence(context: context, document: document,
                    email: staffEmail, stamp: workspaceStamp)
                guard GunnAireCloudKit.usesTestDatabase || CompanyWorkspaceAccessController.shared.verifiedRole == .admin else {
                    throw CompanyWorkspaceFailure.administratorRequired
                }
            }
            offMainAccess = {
                try await QuickBooksBillingAccessPolicy.checkOffMain(context: context, document: document,
                    email: staffEmail, stamp: workspaceStamp, requiredRole: .admin)
            }
        } else if let validateAccess {
            access = validateAccess
            offMainAccess = nil
        } else if case .estimate = document {
            access = {
                try QuickBooksBillingAccessPolicy.checkLocalFence(context: context, document: document,
                    email: staffEmail, stamp: workspaceStamp)
            }
            offMainAccess = {
                try await QuickBooksBillingAccessPolicy.checkOffMain(context: context, document: document,
                    email: staffEmail, stamp: workspaceStamp)
            }
        } else {
            access = {
                try QuickBooksBillingAccessPolicy.checkLocalFence(context: context, document: document,
                    email: staffEmail, stamp: workspaceStamp)
            }
            offMainAccess = {
                try await QuickBooksBillingAccessPolicy.checkOffMain(context: context, document: document,
                    email: staffEmail, stamp: workspaceStamp)
            }
        }
        try access()
        guard let companyID = fixtureCompanyID ?? CompanyWorkspaceAccessController.shared.verifiedCompanyID,
              let originalCustomer = document.customer else { throw BillingPublicationError.accessRequired }
        self.document = document; self.context = context; self.validateAccess = access
        self.checkAccessOffMain = offMainAccess
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
        if case .estimate = document, selected.count > 20 { throw QuickBooksBillingWorkflowError.changed }
        let capturedItems: [Item]
        if let selectedItemCapture {
            try selectedItemCapture.validate(document: document, context: context)
            capturedItems = selectedItemCapture.items
        } else {
            capturedItems = try QuickBooksBillingReads.items(selected, context: context)
        }
        guard Set(capturedItems.map(\.id)) == selected,
              capturedItems.count == selected.count else { throw QuickBooksBillingWorkflowError.changed }
        self.capturedItems = capturedItems
        let savedItems = Dictionary(uniqueKeysWithValues: capturedItems
            .map { ($0.persistentModelID, QuickBooksCatalogItemRevision($0)) })
        let queuedEstimate: Bool
        if case .estimate = document { queuedEstimate = true } else { queuedEstimate = false }
        let itemPreflight = queuedEstimate ? QuickBooksSelectedItemPreflight() : nil
        selectedItemPreflight = itemPreflight
        if let itemPreflight {
            itemPreflight.validate = {
                guard !context.hasChanges else { throw QuickBooksBillingWorkflowError.changed }
                let observed = try await Task.detached(priority: .userInitiated) { [container = context.container] in
                    let first = try QuickBooksBillingReads.selectedRevisions(container: container, ids: selected)
                    let second = try QuickBooksBillingReads.selectedRevisions(container: container, ids: selected)
                    guard first == second else { throw QuickBooksBillingWorkflowError.changed }
                    return second
                }.value
                guard !context.hasChanges, observed == savedItems else { throw QuickBooksBillingWorkflowError.changed }
            }
        }
        func payments() throws -> [QuickBooksBillingPaymentRevision] {
            try QuickBooksBillingReads.payments(invoiceID: document.id, context: context)
                .sorted { $0.id.uuidString < $1.id.uuidString }.map(QuickBooksBillingPaymentRevision.init)
        }
        let savedPayments = try payments()
        validateOriginal = {
            try checkDocument()
            let customers = try QuickBooksBillingReads.customer(draft.localCustomerID, context: context)
            guard customers.count == 1, customers.first === originalCustomer,
                  QuickBooksCustomerCreateOperation.draft(for: originalCustomer) == draft,
                  originalCustomer.quickBooksID == customerID,
                  try payments() == savedPayments else {
                throw QuickBooksBillingWorkflowError.changed
            }
            if queuedEstimate {
                guard capturedItems.count == selected.count,
                      capturedItems.allSatisfy({ item in
                          item.modelContext === context && !item.isDeleted &&
                          savedItems[item.persistentModelID] == QuickBooksCatalogItemRevision(item)
                      }),
                      !(context.insertedModelsArray + context.deletedModelsArray).contains(where: {
                          ($0 as? Item).map { selected.contains($0.id) } == true
                      }) else { throw QuickBooksBillingWorkflowError.changed }
            } else {
                let current = try QuickBooksBillingReads.items(selected, context: context)
                guard Dictionary(uniqueKeysWithValues: current.map {
                    ($0.persistentModelID, QuickBooksCatalogItemRevision($0))
                }) == savedItems else { throw QuickBooksBillingWorkflowError.changed }
            }
        }
        try validateOriginal()
    }

    func makeWorkflow(lifecycle: QuickBooksSyncLifecycle,
                      billingJournal: BillingNativeJournalStore? = nil) async throws -> QuickBooksBillingWorkflow {
        try operation.check(); try validateOriginal()
        try await checkAccessOffMain?()
        try await selectedItemPreflight?.check()
        try operation.check(); try validateOriginal()
        let guardedClient: BillingPublicationClient
        let guardedCatalog: CatalogPublicationBoundary.Transport
        let guardedCustomer: CustomerPublicationBoundary.Transport
        if checkAccessOffMain != nil || selectedItemPreflight != nil {
            let transport = client.transport
            let selectedItemPreflight = self.selectedItemPreflight
            let checkAccessOffMain = self.checkAccessOffMain
            guardedClient = BillingPublicationClient { path, method, body in
                try await checkAccessOffMain?(); try await selectedItemPreflight?.check()
                let data = try await transport(path, method, body)
                try await checkAccessOffMain?(); try await selectedItemPreflight?.check()
                return data
            }
            let catalog = self.catalog
            guardedCatalog = { request in
                try await checkAccessOffMain?(); try await selectedItemPreflight?.check()
                let response = try await catalog(request)
                try await checkAccessOffMain?(); try await selectedItemPreflight?.check()
                return response
            }
            let customer = self.customer
            guardedCustomer = { request in
                try await checkAccessOffMain?(); try await selectedItemPreflight?.check()
                let response = try await customer(request)
                try await checkAccessOffMain?(); try await selectedItemPreflight?.check()
                return response
            }
        } else {
            guardedClient = client; guardedCatalog = catalog; guardedCustomer = customer
        }
        let connection: SharedBillingConnection
        do {
            let data = try await guardedClient.transport(identity.path, "GET", nil)
            try operation.check(); try validateOriginal()
            guard data.count <= 16_384 else { throw SharedBillingConnectionError.invalid }
            connection = try await SharedBillingConnection.decodeAsync(data)
            try operation.check(); try validateOriginal()
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
            billingPublisher: guardedClient, catalogPublisher: guardedCatalog, customerPublisher: guardedCustomer)
        let lineEvidence = try await QuickBooksSavedLineEvidence.captureAsync(
            snapshotJSON: document.snapshotJSON, expectedSubtotal: document.subtotal)
        try operation.check(); try validateOriginal()
        let catalogAccess: (() throws -> Void)? = checkAccessOffMain == nil ? nil : {
            try self.validateAccess()
            guard CompanyWorkspaceAccessController.shared.verifiedRole == .admin || GunnAireCloudKit.usesTestDatabase else {
                throw CompanyWorkspaceFailure.administratorRequired
            }
        }
        let workflow = try QuickBooksBillingWorkflow(document: document, context: context, api: api,
            lifecycle: lifecycle, validateAccess: self.validateAccess,
            validateCatalogAccess: catalogAccess, billingJournal: billingJournal,
            preparedLineEvidence: lineEvidence, preparedItems: capturedItems)
        selectedItemPreflight?.validate = { [weak workflow] in
            guard let workflow else { throw CancellationError() }
            try await workflow.checkEstimateSelectedItemsOffMain()
        }
        return workflow
    }
}
