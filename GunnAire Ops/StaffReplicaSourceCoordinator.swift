import Foundation
import SwiftData
import Combine
import CryptoKit

struct StaffReplicaSourceRejected: Error { let code: String }
struct StaffReplicaSourceContext {
    let scope: StaffReplicaSourceScope
    let stamp: CompanyWorkspaceOperationStamp
}

struct StaffReplicaSourceDependencies {
    let context: () async throws -> StaffReplicaSourceContext
    let check: (StaffReplicaSourceContext) throws -> Void
    let capture: (StaffReplicaSourceContext, Data?) throws -> StaffReplicaSourceCapture
    let request: (String, String, Data?) async throws -> Data
    let store: SharedTimeLocalStore
    var now: () -> Date = Date.init
    var deliver: ((StaffReplicaSourceContext, Int) async throws -> StaffReplicaAutomaticSummary)? = nil
    var prepareFullWorkspace: ((StaffReplicaSourceContext) throws -> Void)? = nil
    var fullWorkspace: StaffWorkspacePublicationCoordinator? = nil
    var fullContent: StaffWorkspaceContentCoordinator? = nil
    var ownerFieldEdits: StaffOwnerFieldEditCoordinator? = nil

    static func verify(_ context: StaffReplicaSourceContext) throws {
        try Task.checkCancellation()
        let access = CompanyWorkspaceAccessController.shared
        guard !GunnAireCloudKit.usesTestDatabase, access.operationStamp == context.stamp, access.verifiedRole == .admin,
              access.verifiedCompanyID == context.scope.binding.companyID, Date() < context.stamp.session.expiresAt,
              try CompanyWorkspaceStore.identity(at: CompanyWorkspaceStore.url) == context.scope.storeUUID else {
            throw StaffReplicaSourceSyncError.access
        }
    }

    static var live: Self {
        .init(context: {
            let access = CompanyWorkspaceAccessController.shared
            guard !GunnAireCloudKit.usesTestDatabase, let stamp = access.operationStamp, access.verifiedRole == .admin else {
                throw StaffReplicaSourceSyncError.access
            }
            let response = try await GunnAireBackendService.fetchCompanyWorkspace()
            let account = try await CompanyCloudKitRuntimeAccount.current()
            guard access.operationStamp == stamp, response.user.email == stamp.session.email, response.user.isActive,
                  response.user.role == AppUserRole.admin.rawValue, let binding = response.workspace.binding(for: account.environment),
                  binding.companyID == access.verifiedCompanyID, binding.cloudAccountHash == account.accountHash,
                  let registration = try KeychainStore.loadCodable(CompanyWorkspaceStoreRegistration.self, account: "GunnAireCompanyStoreRegistration"),
                  registration.matches(session: stamp.session, binding: binding, storeUUID: try CompanyWorkspaceStore.identity(at: CompanyWorkspaceStore.url)) else {
                throw StaffReplicaSourceSyncError.access
            }
            return .init(scope: .init(backendOrigin: stamp.session.backendOrigin, actorEmail: stamp.session.email,
                                     binding: binding, storeUUID: registration.storeUUID), stamp: stamp)
        }, check: { try verify($0) }, capture: { context, token in
            guard let container = CompanyWorkspaceAccessController.shared.authorizedContainer else { throw StaffReplicaSourceSyncError.access }
            return try StaffReplicaSourceHistory.capture(container: container, after: token, storeUUID: context.scope.storeUUID)
        }, request: { try await GunnAireBackendService.staffReplicaSourceRequest(path: $0, method: $1, body: $2) }, store: StaffReplicaSourceStorage.device,
              deliver: { try await StaffReplicaAutomaticDelivery().deliver(source: $0, sequence: $1) },
              fullWorkspace: .shared, fullContent: .shared, ownerFieldEdits: .shared)
    }
}

enum StaffReplicaSourceStorage {
    static var device: SharedTimeLocalStore {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw StaffReplicaSourceSyncError.storage }, write: { _, _ in throw StaffReplicaSourceSyncError.storage })
        }
        return .encrypted(directory: root.appendingPathComponent("StaffReplicaSource-v1", isDirectory: true), maximumBytes: 64 * 1024 * 1024) { create in
            let name = "StaffReplicaSourceEncryption-v1"
            if let bytes = try KeychainStore.loadCodable(Data.self, account: name) {
                guard bytes.count == 32 else { throw StaffReplicaSourceSyncError.storage }; return bytes
            }
            guard create else { throw StaffReplicaSourceSyncError.storage }
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(bytes, account: name); return bytes
        }
    }
}

/// The owner SwiftData store remains authoritative. This prepares the explicit
/// core-field source ledger; it does not import partial models or claim delivery.
@MainActor final class StaffReplicaSourceCoordinator: ObservableObject {
    static let shared = StaffReplicaSourceCoordinator()
    @Published private(set) var isRunning = false
    @Published private(set) var message = "Saved changes will be prepared when the approved owner workspace is connected."
    @Published private(set) var conflicts: [StaffReplicaSourceConflict] = []
    @Published private(set) var lastConfirmedAt: Date?
    @Published private(set) var hasMore = false
    @Published private(set) var workspaceConflicts: [StaffWorkspacePublicationConflict] = []
    private var displayScope: StaffReplicaSourceScope?
    let dependencies: StaffReplicaSourceDependencies
    var ownerFieldEdits: StaffOwnerFieldEditCoordinator? { dependencies.ownerFieldEdits }
    init(dependencies: StaffReplicaSourceDependencies? = nil) { self.dependencies = dependencies ?? .live }

    func clearDisplay() {
        conflicts = []; lastConfirmedAt = nil; displayScope = nil; hasMore = false
        workspaceConflicts = []; dependencies.fullWorkspace?.clearCache()
        dependencies.ownerFieldEdits?.clearDisplay()
        message = "Verify the approved owner workspace to prepare staff data."
    }
    private func load(_ context: StaffReplicaSourceContext) throws -> StaffReplicaSourceJournal {
        try dependencies.check(context)
        guard let data = try dependencies.store.read(context.scope.key) else { return .init(scope: context.scope) }
        guard data.count <= 64 * 1024 * 1024 else { throw StaffReplicaSourceSyncError.storage }
        let value = try JSONDecoder().decode(StaffReplicaSourceJournal.self, from: data)
        guard value.scope == context.scope, value.rejected.count <= 1000,
              value.baseline.allSatisfy({ $0.key == $0.value.key }),
              value.decisions.allSatisfy({ $0.key == $0.value.remote.key && ($0.value.local == nil || $0.value.local?.key == $0.key) }) else {
            throw StaffReplicaSourceSyncError.storage
        }
        try value.baseline.values.forEach { try $0.validate(context.scope) }
        try value.pending?.validate(context.scope)
        try value.rejected.forEach { try $0.validate(context.scope) }
        return value
    }
    private func save(_ journal: StaffReplicaSourceJournal, _ context: StaffReplicaSourceContext) throws {
        try dependencies.check(context)
        guard journal.scope == context.scope else { throw StaffReplicaSourceSyncError.storage }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 64 * 1024 * 1024 else { throw StaffReplicaSourceSyncError.storage }
        try dependencies.store.write(context.scope.key, data)
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil, context: StaffReplicaSourceContext) async throws -> Data {
        try dependencies.check(context)
        guard StaffReplicaSourceTransportPolicy.allows(path: path, method: method, body: body) else { throw StaffReplicaSourceSyncError.invalid }
        let result = try await dependencies.request(path, method, body)
        try dependencies.check(context)
        guard result.count <= 8 * 1024 * 1024 else { throw StaffReplicaSourceSyncError.invalid }
        return result
    }
    private func readSource(_ context: StaffReplicaSourceContext) async throws -> (Int, [StaffReplicaSourceRemoteRecord]) {
        var records: [StaffReplicaSourceRemoteRecord] = [], sequence: Int?, after: String?, total = 0, authority: Int?
        repeat {
            let data = try await request(StaffReplicaSourceTransportPolicy.path(scope: context.scope, sequence: sequence, after: after), context: context)
            total += data.count
            guard total <= 64 * 1024 * 1024 else { throw StaffReplicaSourceSyncError.invalid }
            let page = try JSONDecoder().decode(StaffReplicaSourcePage.self, from: data)
            try page.validate(context.scope, sequence: sequence, after: after)
            guard authority == nil || authority == page.authorizationSequence else { throw StaffReplicaSourceSyncError.invalid }
            authority = page.authorizationSequence; sequence = page.sequence; records += page.records; after = page.nextCursor
            guard records.count <= 20_000 else { throw StaffReplicaSourceSyncError.invalid }
        } while after != nil
        // Even a one-page read has an explicit end fence. A moving source never
        // becomes a fabricated complete snapshot or an updated local baseline.
        let final = try JSONDecoder().decode(StaffReplicaSourcePage.self, from: await request(
            StaffReplicaSourceTransportPolicy.path(scope: context.scope, sequence: sequence), context: context))
        try final.validate(context.scope, sequence: sequence, after: nil)
        guard final.authorizationSequence == authority, final.records == Array(records.prefix(100)) else { throw StaffReplicaSourceSyncError.invalid }
        return (final.sequence, records)
    }
    private func recover(_ journal: inout StaffReplicaSourceJournal, context: StaffReplicaSourceContext) async throws {
        guard let batch = journal.pending else { return }
        try batch.validate(context.scope)
        let bytes = try Self.encode(batch)
        do {
            let data = try await request(StaffReplicaSourceTransportPolicy.root, method: "POST", body: bytes, context: context)
            let receipt = try JSONDecoder().decode(StaffReplicaSourceReceipt.self, from: data)
            try receipt.validate(batch, scope: context.scope)
            for change in batch.changes {
                let fields = change.action == "delete" ? (journal.baseline[change.key]?.fields ?? [:]) : change.fields
                journal.baseline[change.key] = .init(companyID: context.scope.binding.companyID, environment: context.scope.binding.environment,
                    replicaID: context.scope.binding.replicaID, kind: change.kind, id: change.id,
                    revision: change.expectedRevision + 1, deleted: change.action == "delete", fields: fields)
                if change.action == "delete" { journal.deletions.remove(change.key) }
                journal.decisions[change.key] = nil
            }
            journal.pending = nil; journal.lastConfirmedAt = dependencies.now()
            try save(journal, context)
        } catch let rejection as StaffReplicaSourceRejected {
            try dependencies.check(context)
            guard ["source_changed", "record_changed", "deletion_changed"].contains(rejection.code), journal.rejected.count < 1000 else {
                throw StaffReplicaSourceSyncError.storage
            }
            // This exact server rejection proves no mutation occurred. Archive
            // the original rather than changing its ID/body or losing recovery.
            journal.rejected.append(batch); journal.pending = nil
            try save(journal, context)
            throw StaffReplicaSourceSyncError.sourceChanged
        }
    }
    static func encode(_ batch: StaffReplicaSourceBatch) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(batch)
    }

    func applyFieldReview(_ review: StaffOwnerFieldEditReview) async {
        guard !isRunning, let edits = dependencies.ownerFieldEdits else { return }
        isRunning = true
        do {
            let context = try await dependencies.context()
            try dependencies.check(context)
            guard displayScope == context.scope else { throw StaffReplicaSourceSyncError.access }
            try await edits.applyReviewed(review, context: context)
            isRunning = false
            await sync()
        } catch {
            isRunning = false
            message = (error as? StaffOwnerFieldEditError)?.localizedDescription ?? "The reviewed field edit changed or could not be saved. Check again; the original was retained."
        }
    }

    func sync() async {
        guard !isRunning else { return }
        isRunning = true; hasMore = false
        defer { isRunning = false }
        do {
            let context = try await dependencies.context()
            try dependencies.check(context)
            if displayScope != context.scope { clearDisplay(); displayScope = context.scope }
            var journal = try load(context)
            // Original in-flight requests are recovered before capturing newer
            // edits, including after process death or a lost acknowledgement.
            try await recover(&journal, context: context)
            try await dependencies.ownerFieldEdits?.synchronize(context)
            try dependencies.check(context)
            // Prepare all 32 owner model kinds durably under a separate local
            // schema before publishing newer core facts. Never alter recovery
            // of an already submitted six-kind operation or send raw HR/billing
            // records through the existing role-projected core endpoint.
            if let publisher = dependencies.fullWorkspace {
                let summary = try await publisher.synchronize(context)
                try dependencies.check(context)
                workspaceConflicts = summary.conflicts
                if summary.hasMore || !summary.conflicts.isEmpty || summary.waitingForCloudKit > 0 {
                    message = summary.message; hasMore = summary.hasMore; lastConfirmedAt = summary.lastConfirmedAt
                    return
                }
                try await dependencies.ownerFieldEdits?.confirmPublished(context)
                try dependencies.check(context)
                if let content = dependencies.fullContent {
                    let prepared = try await content.synchronize(context, published: summary)
                    try dependencies.check(context)
                    if prepared.hasMore {
                        message = prepared.message; hasMore = true; return
                    }
                }
                guard try publisher.matchesCurrent(summary.preparedStage, context: context) else {
                    hasMore = true; message = "Checking newer saved work before sharing…"
                    return
                }
                // No suspension between this owner-history fence and the core
                // capture below: both use the same verified owner workspace.
            } else { try dependencies.prepareFullWorkspace?(context) }
            try dependencies.check(context)
            let capture = try dependencies.capture(context, journal.token)
            try dependencies.check(context)
            journal.snapshot = capture.source; journal.token = capture.token
            journal.deletions.formUnion(capture.deletions)
            journal.deletions.subtract(capture.source.records.map(\.key))
            try save(journal, context) // Cursor and original facts durable before network publication.
            let (sequence, records) = try await readSource(context)
            let plan = try StaffReplicaSourcePlan.reconcile(journal: &journal, remote: records)
            conflicts = plan.conflicts
            try save(journal, context)
            var selected: [StaffReplicaSourceChange] = []
            for change in plan.changes.prefix(100) {
                let candidate = StaffReplicaSourceBatch(scope: context.scope, sequence: sequence, changes: selected + [change])
                if try Self.encode(candidate).count > 1024 * 1024 { break }
                selected.append(change)
            }
            if !selected.isEmpty {
                journal.pending = .init(scope: context.scope, sequence: sequence, changes: selected)
                try save(journal, context) // Original operation exists before the first POST.
                try await recover(&journal, context: context)
            }
            lastConfirmedAt = journal.lastConfirmedAt
            hasMore = selected.count < plan.changes.count
            if !conflicts.isEmpty { message = "\(conflicts.count) saved change\(conflicts.count == 1 ? " needs" : "s need") review." }
            else if plan.waitingForCloudKit > 0 { message = "Waiting for this device's company iCloud records to catch up." }
            else if hasMore { message = "Preparing more saved changes…" }
            else if let deliver = dependencies.deliver {
                if !selected.isEmpty {
                    // Re-capture and fence the acknowledged source in the next
                    // pass before preparing snapshots from its final sequence.
                    hasMore = true; message = "Checking saved changes before sharing…"
                } else {
                    message = "Sharing saved changes through iCloud…"
                    let summary = try await deliver(context, sequence)
                    try dependencies.check(context)
                    message = summary.message
                }
            } else { message = "Core records prepared. Staff device delivery is a separate step." }
        } catch is CancellationError {
            // The durable original is retained for the next foreground run.
        } catch {
            if case StaffReplicaSourceSyncError.access = error { clearDisplay() }
            if let safe = error as? StaffReplicaSourceSyncError { message = safe.localizedDescription }
            else if let safe = error as? StaffReplicaSourceError { message = safe.localizedDescription }
            else if let safe = error as? StaffReplicaDeliveryError { message = safe.localizedDescription }
            else { message = StaffReplicaSourceSyncError.unavailable.localizedDescription }
        }
    }

    func approve(_ conflict: StaffReplicaSourceConflict) async {
        guard !isRunning, conflicts.contains(conflict), conflict.local != nil || conflict.deletion else { return }
        do {
            let context = try await dependencies.context()
            guard context.scope == displayScope else { throw StaffReplicaSourceSyncError.access }
            var journal = try load(context)
            journal.decisions[conflict.id] = .init(local: conflict.local, remote: conflict.remote)
            try save(journal, context)
            await sync() // New capture and server read must still match the approved values.
        } catch { message = StaffReplicaSourceSyncError.unavailable.localizedDescription }
    }

    func approveWorkspace(_ conflict: StaffWorkspacePublicationConflict) async {
        guard !isRunning, workspaceConflicts.contains(conflict), let publisher = dependencies.fullWorkspace else { return }
        do {
            let context = try await dependencies.context()
            guard context.scope == displayScope else { throw StaffReplicaSourceSyncError.access }
            try publisher.approve(conflict, context: context)
            await sync()
        } catch {
            if case StaffReplicaSourceSyncError.access = error { clearDisplay() }
            message = (error as? StaffReplicaSourceSyncError)?.localizedDescription ?? StaffReplicaSourceSyncError.unavailable.localizedDescription
        }
    }
}
