import Foundation
import SwiftData

enum QuickBooksSyncAccessPolicy {
    static func allows(email: String?, users: [AppUser], verifiedRole: AppUserRole?) -> Bool {
        let email = AppAccess.normalizedEmail(email)
        let matches = users.filter { AppAccess.normalizedEmail($0.email) == email }
        // Do not use the legacy primary-email administrator shortcut here.
        return !email.isEmpty && verifiedRole == .admin && !matches.isEmpty &&
            matches.allSatisfy { $0.isActive && $0.role == .admin }
    }

    static func validate(context: ModelContext) throws {
        let controller = CompanyWorkspaceAccessController.shared
        let users = try context.fetch(FetchDescriptor<AppUser>())
        let fixture = GunnAireCloudKit.usesTestDatabase
        guard (fixture || controller.authorizedContainer === context.container),
              allows(email: AppIdentity.currentEmail, users: users,
                     verifiedRole: fixture ? .admin : controller.verifiedRole) else {
            throw CompanyWorkspaceFailure.administratorRequired
        }
    }
}

/// One owner for resource results, local commits and change-queue follow-up.
/// A replaced/cancelled run cannot complete or clear a newer run's UI state.
@MainActor
final class QuickBooksSyncLifecycle {
    private(set) var activeID: UUID?

    func begin(api: QuickBooksDataAPI, sharedHistoryRequest: QuickBooksChangeHistoryClient.Request? = nil,
               validateAccess: @escaping () throws -> Void) throws -> QuickBooksSyncRun {
        try validateAccess()
        let id = UUID()
        let workflow = try api.captureWorkspaceWorkflow { [weak self] in
            guard self?.activeID == id else { return false }
            do { try validateAccess(); return true } catch { return false }
        }
        activeID = id
        let run = QuickBooksSyncRun(id: id, workflow: workflow) { [weak self] in
            guard self?.activeID == id else { throw CancellationError() }
            try validateAccess()
        }
        do {
            if let sharedHistoryRequest { try run.configureSharedHistory(request: sharedHistoryRequest) }
            return run
        } catch {
            if activeID == id { activeID = nil }
            throw error
        }
    }

    func isCurrent(_ run: QuickBooksSyncRun) -> Bool { activeID == run.id }
    func cancel() { activeID = nil }

    @discardableResult
    func finish(_ run: QuickBooksSyncRun) -> Bool {
        guard isCurrent(run) else { return false }
        activeID = nil
        return true
    }
}

@MainActor
final class QuickBooksSyncRun {
    let id: UUID
    let workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow
    private let validateAccess: () throws -> Void
    private(set) var successfulResourceIDs: Set<String> = []
    private(set) var sharedHistory: QuickBooksChangeHistoryClient?

    fileprivate init(id: UUID, workflow: QuickBooksDataAPI.CapturedWorkspaceWorkflow,
                     validateAccess: @escaping () throws -> Void) {
        self.id = id
        self.workflow = workflow
        self.validateAccess = validateAccess
    }

    func check() throws {
        try validateAccess()
        try workflow.check()
    }

    func perform<T>(_ body: () async throws -> T) async throws -> T {
        try check()
        do {
            return try await workflow.perform { _ in
                try self.check()
                let result = try await body()
                try self.check()
                return result
            }
        } catch {
            // Provider transport also checks this run's lifetime. Restore the
            // specific cancelled/role outcome before presenting its generic
            // changed-connection error to the caller.
            try check()
            throw error
        }
    }

    func receive<T>(_ fetch: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await perform {
            let result: Result<T, Error> = await withCheckedContinuation { continuation in
                fetch { continuation.resume(returning: $0) }
            }
            // Check after callback delivery AND after resuming the caller.
            try self.check()
            return try result.get()
        }
    }

    fileprivate func configureSharedHistory(request: @escaping QuickBooksChangeHistoryClient.Request) throws {
        guard let companyID = workflow.companyID, let realmID = workflow.realmID
        else { throw QuickBooksChangeHistoryError.access }
        sharedHistory = try QuickBooksChangeHistoryClient(
            scope: .init(companyID: companyID, realmID: realmID, environment: workflow.environment.lowercased()),
            check: { [weak self] in
                guard let self else { throw CancellationError() }
                try self.check()
            }, request: request)
    }

    func receiveResource<T: Decodable>(id: String,
        fetch: (@escaping (Result<[T], Error>) -> Void) -> Void) async throws -> [T] {
        if let sharedHistory, let entity = QuickBooksChangeEntity(resourceID: id) {
            return try await perform { try await sharedHistory.records(entity: entity, as: T.self) }
        }
        return try await receive(fetch)
    }

    @discardableResult
    func prepareLocalImport() async throws -> QuickBooksCatalogHistoryBatch? {
        try check()
        guard let sharedHistory else { return nil }
        let entities = Set(QuickBooksChangeEntity.allCases)
        guard entities.allSatisfy({ successfulResourceIDs.contains($0.resourceID) })
        else { throw QuickBooksChangeHistoryError.incomplete }
        try await perform { try await sharedHistory.revalidate(entities) }
        try check()
        return try sharedHistory.catalogHistory()
    }

    func commit(_ body: () throws -> Void) throws {
        try check()
        try body()
    }

    func markSucceeded(_ resourceID: String) throws {
        try check()
        successfulResourceIDs.insert(resourceID)
    }
}
