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

    func begin(api: QuickBooksDataAPI, validateAccess: @escaping () throws -> Void) throws -> QuickBooksSyncRun {
        try validateAccess()
        let id = UUID()
        let workflow = try api.captureWorkspaceWorkflow { [weak self] in
            guard self?.activeID == id else { return false }
            do { try validateAccess(); return true } catch { return false }
        }
        activeID = id
        return QuickBooksSyncRun(id: id, workflow: workflow) { [weak self] in
            guard self?.activeID == id else { throw CancellationError() }
            try validateAccess()
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

    func commit(_ body: () throws -> Void) throws {
        try check()
        try body()
    }

    func markSucceeded(_ resourceID: String) throws {
        try check()
        successfulResourceIDs.insert(resourceID)
    }
}
