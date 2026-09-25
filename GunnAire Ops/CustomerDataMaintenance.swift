import Foundation
import SwiftData

nonisolated enum CustomerCalendarCleanupError: LocalizedError {
    case accessChanged, recordsChanged

    var errorDescription: String? {
        switch self {
        case .accessChanged: "Calendar cleanup stopped because administrator access changed. No cleanup changes were saved."
        case .recordsChanged: "Calendar customer records changed during cleanup. No cleanup changes were saved. Try again."
        }
    }
}

/// Revocation and the decision to begin a commit share one short lock. The
/// database save never holds this lock or blocks the main actor. A save that
/// already began may finish; revocation before begin always rejects the permit.
nonisolated final class CompanyWorkspaceMutationEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        valid = false
    }

    fileprivate func begin(_ check: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw CustomerCalendarCleanupError.accessChanged }
        try check()
    }
}

nonisolated final class CustomerCleanupCommitPermit: @unchecked Sendable {
    private let epoch: CompanyWorkspaceMutationEpoch
    private let issuedAt: Date
    private let expiresAt: Date
    private let lock = NSLock()
    private var used = false

    init(epoch: CompanyWorkspaceMutationEpoch, issuedAt: Date, expiresAt: Date) {
        self.epoch = epoch; self.issuedAt = issuedAt; self.expiresAt = expiresAt
    }

    func beginCommit(now: Date = Date(), checkCancellation: () throws -> Void = {}) throws {
        lock.lock(); defer { lock.unlock() }
        try epoch.begin {
            try checkCancellation()
            guard !used, now >= issuedAt, now < expiresAt else {
                throw CustomerCalendarCleanupError.accessChanged
            }
            used = true
        }
    }
}

nonisolated struct CustomerCalendarCleanupPlan: Sendable {
    nonisolated struct Candidate: Sendable, Equatable {
        let persistentID: PersistentIdentifier
        let id: UUID
        let name: String
        let quickBooksID: String?

        init(_ customer: Customer) {
            persistentID = customer.persistentModelID
            id = customer.id; name = customer.name; quickBooksID = customer.quickBooksID
        }
    }

    let candidates: [Candidate]
    let summary: CustomerDataMaintenance.DeletionSummary

    func validate(in context: ModelContext) throws {
        let current = try context.fetch(FetchDescriptor<Customer>())
        for candidate in candidates {
            let matches = current.filter { $0.id == candidate.id }
            guard matches.count == 1, let customer = matches.first,
                  Candidate(customer) == candidate,
                  CustomerDataMaintenance.isGenericCalendarCustomer(customer),
                  !CustomerDataMaintenance.isSystemCalendarCustomer(customer) else {
                throw CustomerCalendarCleanupError.recordsChanged
            }
        }
    }
}

nonisolated private final class CustomerCleanupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}

/// The context and every retained model are created, accessed and retired only
/// on this queue. Only the immutable plan and authorization permit cross it.
nonisolated private final class CustomerCalendarCleanupTransaction: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gunnaire.calendar.cleanup", qos: .utility)
    private let container: ModelContainer
    private var context: ModelContext?

    init(container: ModelContainer) { self.container = container }

    func stage(cancellation: CustomerCleanupCancellation) async throws -> CustomerCalendarCleanupPlan {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try cancellation.check()
                    let context = ModelContext(self.container)
                    context.autosaveEnabled = false
                    self.context = context
                    let plan = try CustomerDataMaintenance.stageCalendarNamedCustomers(modelContext: context)
                    try cancellation.check()
                    continuation.resume(returning: plan)
                } catch {
                    self.context?.rollback(); self.context = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func commit(_ plan: CustomerCalendarCleanupPlan, permit: CustomerCleanupCommitPermit,
                cancellation: CustomerCleanupCancellation,
                beforeCommit: @escaping @Sendable () throws -> Void,
                save: @escaping @Sendable (ModelContext) throws -> Void) async throws -> CustomerDataMaintenance.DeletionSummary {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let context = self.context else { throw CustomerCalendarCleanupError.recordsChanged }
                    try cancellation.check()
                    try beforeCommit()
                    // Read through a fresh context so an edit made while the
                    // authorization callback awaited cannot delete a renamed or
                    // newly linked customer from the older staged snapshot.
                    let latest = ModelContext(self.container)
                    latest.autosaveEnabled = false
                    try plan.validate(in: latest)
                    try permit.beginCommit(checkCancellation: { try cancellation.check() })
                    try save(context)
                    self.context = nil
                    continuation.resume(returning: plan.summary)
                } catch {
                    self.context?.rollback(); self.context = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func rollback() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.context?.rollback(); self.context = nil
                continuation.resume()
            }
        }
    }
}

nonisolated enum CustomerCalendarCleanup {
    static func run(container: ModelContainer,
                    authorize: @escaping @MainActor @Sendable () async throws -> CustomerCleanupCommitPermit,
                    beforeCommit: @escaping @Sendable () throws -> Void = {},
                    save: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() }) async throws -> CustomerDataMaintenance.DeletionSummary {
        let cancellation = CustomerCleanupCancellation()
        let transaction = CustomerCalendarCleanupTransaction(container: container)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let plan = try await transaction.stage(cancellation: cancellation)
                let permit = try await authorize()
                return try await transaction.commit(plan, permit: permit, cancellation: cancellation,
                    beforeCommit: beforeCommit, save: save)
            } catch {
                await transaction.rollback()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
