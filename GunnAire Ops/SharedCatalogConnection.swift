import Foundation
import SwiftData

enum CatalogPublicationTransportPolicy {
    static func allows(path: String, method: String, bodyBytes: Int?) -> Bool {
        guard let url = URLComponents(string: path), url.scheme == nil, url.host == nil, url.fragment == nil,
              path.utf8.count <= 8192, (bodyBytes ?? 0) >= 0, (bodyBytes ?? 0) <= 32768 else { return false }
        let base = "/api/catalog-publications"
        if method == "GET", bodyBytes == nil, [base, base + "/context"].contains(url.path) {
            let pairs = url.queryItems ?? []
            return pairs.count == 2 && Set(pairs.map(\.name)) == ["companyID", "localItemID"] &&
                pairs.allSatisfy { $0.value.flatMap(UUID.init(uuidString:)) != nil }
        }
        guard method == "POST", bodyBytes != nil, url.query == nil else { return false }
        if url.path == base { return true }
        guard url.path.hasPrefix(base + "/") else { return false }
        let parts = url.path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])).map { $0.uuidString.lowercased() == parts[0] } == true &&
            ["recover", "cancel"].contains(String(parts[1]))
    }
}

struct SharedCatalogIdentity: Equatable {
    let companyID: UUID
    let localItemID: UUID
    var path: String {
        "/api/catalog-publications/context?companyID=\(companyID.uuidString.lowercased())&localItemID=\(localItemID.uuidString.lowercased())"
    }
}

struct SharedCatalogComparisonScope: Equatable {
    let companyID: UUID
    let realmID: String
    let environment: String
    let connectionRevision: String

    init?(_ workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow?) {
        guard let workflow, let companyID = workflow.companyID, let realmID = workflow.realmID,
              let revision = workflow.sharedBillingConnectionRevision,
              JobBillingAssignmentSnapshot.validConnectionRevision(revision) else { return nil }
        self.companyID = companyID; self.realmID = realmID; self.environment = workflow.environment
        self.connectionRevision = revision
    }
}

struct SharedCatalogConnection: Decodable {
    let companyID: UUID
    let localItemID: UUID
    let realmID: String
    let environment: String
    let connectionRevision: String
    let protocolVersion: Int
    let incomeAccount: QuickBooksReference?
    let expenseAccount: QuickBooksReference?
    let item: QuickBooksItem?

    func validate(_ identity: SharedCatalogIdentity) throws {
        guard companyID == identity.companyID, localItemID == identity.localItemID, protocolVersion == 1,
              PaymentAttemptRecord.isReference(realmID), ["sandbox", "production"].contains(environment),
              JobBillingAssignmentSnapshot.validConnectionRevision(connectionRevision),
              incomeAccount.map({ PaymentAttemptRecord.isReference($0.value) }) ?? true,
              expenseAccount.map({ PaymentAttemptRecord.isReference($0.value) }) ?? true else {
            throw CatalogPublicationError.invalidResponse
        }
        if let item {
            guard PaymentAttemptRecord.isReference(item.Id), item.SyncToken.map({ PaymentAttemptRecord.isReference($0) }) == true,
                  item.Active != nil, CatalogItemType(rawValue: item.ItemType ?? "")?.isDirectSalesItem == true,
                  !item.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (item.UnitPrice ?? 0).isFinite, (0...99_999_999_999).contains(item.UnitPrice ?? 0),
                  (item.PurchaseCost ?? 0).isFinite, (0...99_999_999_999).contains(item.PurchaseCost ?? 0) else {
                throw CatalogPublicationError.invalidResponse
            }
            if item.ItemType == "Inventory" { try QuickBooksCatalogDetails(item).validateInventory() }
        }
    }

    var configuration: BackendQuickBooksAccountingConfiguration {
        .init(realmID: realmID, environment: environment,
              defaultSalesItemRef: "", defaultSalesItemName: "", defaultSalesItemType: "",
              defaultIncomeAccountRef: incomeAccount?.value ?? "", defaultIncomeAccountName: incomeAccount?.name ?? "", defaultIncomeAccountType: "Income",
              defaultExpenseAccountRef: expenseAccount?.value ?? "", defaultExpenseAccountName: expenseAccount?.name ?? "", defaultExpenseAccountType: "Expense",
              defaultAPAccountRef: "", defaultAPAccountName: "", defaultAPAccountType: "",
              defaultBankAccountRef: "", defaultBankAccountName: "", defaultBankAccountType: "",
              defaultCreditCardAccountRef: "", defaultCreditCardAccountName: "", defaultCreditCardAccountType: "",
              updatedAt: nil, updatedBy: nil)
    }
}

@MainActor
struct SharedCatalogClient {
    var transport: (String, String, Data?) async throws -> Data
    static var live: Self { .init(transport: GunnAireBackendService.catalogPublicationRequest) }

    func connection(_ identity: SharedCatalogIdentity) async throws -> SharedCatalogConnection {
        do {
            let data = try await transport(identity.path, "GET", nil)
            guard data.count <= 32768 else { throw CatalogPublicationError.invalidResponse }
            let result = try JSONDecoder().decode(SharedCatalogConnection.self, from: data)
            try result.validate(identity)
            return result
        } catch { throw Self.safe(error) }
    }

    func publish(_ request: CatalogPublicationRequest) async throws -> CatalogPublicationResponse {
        do {
            let data = try await transport("/api/catalog-publications", "POST", JSONEncoder().encode(request))
            guard data.count <= 32768 else { throw CatalogPublicationError.invalidResponse }
            let result = try JSONDecoder().decode(CatalogPublicationResponse.self, from: data)
            try result.validate(companyID: request.companyID, realmID: request.realmID,
                environment: request.environment, itemID: request.localItemID)
            return result
        } catch { throw Self.safe(error) }
    }

    func recover(_ id: UUID) async throws -> CatalogPublicationResponse {
        do {
            let data = try await transport("/api/catalog-publications/\(id.uuidString.lowercased())/recover", "POST", Data("{}".utf8))
            guard data.count <= 32768 else { throw CatalogPublicationError.invalidResponse }
            return try JSONDecoder().decode(CatalogPublicationResponse.self, from: data)
        } catch { throw Self.safe(error) }
    }

    static func safe(_ error: Error) -> Error {
        if error is CancellationError || error is WorkspaceProviderAccessError || error is CatalogPublicationError { return error }
        if error is DecodingError { return CatalogPublicationError.invalidResponse }
        if case GunnAireBackendError.server(let status, _) = error {
            if status == 401 || status == 403 { return CatalogPublicationError.accessRequired }
            if status == 400 { return CatalogPublicationError.invalidProposal }
            if status == 409 { return CatalogPublicationError.needsReview }
        }
        return CatalogPublicationError.unavailable
    }
}

/// Captured at the original user action, before discovery can suspend. No
/// device OAuth, cached realm, inferred provider link or direct-provider fallback.
@MainActor
final class SharedCatalogPreparation {
    let identity: SharedCatalogIdentity
    private let item: Item
    private let context: ModelContext
    private let revision: QuickBooksCatalogItemRevision
    private let operation: WorkspaceProviderOperation
    private let validateAccess: () throws -> Void
    private let client: SharedCatalogClient

    init(item: Item, context: ModelContext, isCurrent: @escaping () -> Bool,
         client: SharedCatalogClient? = nil, fixtureCompanyID: UUID? = nil,
         validateAccess: (() throws -> Void)? = nil) throws {
        if fixtureCompanyID != nil { precondition(GunnAireCloudKit.usesTestDatabase) }
        let access = validateAccess ?? { try QuickBooksSyncAccessPolicy.validate(context: context) }
        try access()
        guard let company = fixtureCompanyID ?? CompanyWorkspaceAccessController.shared.verifiedCompanyID else {
            throw CatalogPublicationError.accessRequired
        }
        self.item = item; self.context = context; self.revision = .init(item)
        self.identity = .init(companyID: company, localItemID: item.id)
        self.client = client ?? .live; self.validateAccess = access
        operation = try WorkspaceProviderOperation.capture {
            guard isCurrent() else { return false }
            do { try access(); return true } catch { return false }
        }
        try check()
    }

    func check() throws {
        try operation.check(); try validateAccess()
        let matches = try context.fetch(FetchDescriptor<Item>()).filter { $0.id == identity.localItemID }
        guard matches.count == 1, matches.first === item, QuickBooksCatalogItemRevision(item) == revision else {
            throw QuickBooksCatalogWorkflowError.itemChanged
        }
    }

    func connection() async throws -> SharedCatalogConnection {
        try check()
        do {
            let value = try await client.connection(identity)
            try check()
            return value
        } catch { try check(); throw error }
    }

    func makeWorkflow(lifecycle: QuickBooksSyncLifecycle, mode: QuickBooksCatalogWorkflow.Mode) async throws -> QuickBooksCatalogWorkflow {
        let original = try await connection()
        let api = QuickBooksDataAPI(sharedCompanyID: identity.companyID, realmID: original.realmID,
            environment: original.environment, connectionRevision: original.connectionRevision, operation: operation,
            billingPublisher: .init { _, _, _ in throw BillingPublicationError.accessRequired },
            catalogPublisher: client.publish, catalogRecovery: client.recover,
            catalogRead: { [self] identifier in
                let fresh = try await connection()
                guard fresh.realmID == original.realmID, fresh.environment == original.environment,
                      fresh.connectionRevision == original.connectionRevision else { throw CatalogPublicationError.needsReview }
                guard let remote = fresh.item, remote.Id == identifier else { throw QuickBooksCatalogWorkflowError.remoteIdentity }
                return remote
            })
        return try QuickBooksCatalogWorkflow(item: item, context: context, api: api, lifecycle: lifecycle,
            mode: mode, configuration: original.configuration, validateAccess: validateAccess)
    }
}
