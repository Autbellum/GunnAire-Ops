import Foundation

struct StaffWorkspacePublicationDependencies {
    let check: (StaffReplicaSourceContext) throws -> Void
    let prepare: (StaffReplicaSourceContext) throws -> StaffWorkspaceSourceJournal
    let request: (String, String, Data?) async throws -> Data
    let store: SharedTimeLocalStore
    var now: () -> Date = Date.init

    static var live: Self {
        .init(check: { try StaffReplicaSourceDependencies.verify($0) }, prepare: { context in
            try StaffReplicaSourceDependencies.verify(context)
            guard let container = CompanyWorkspaceAccessController.shared.authorizedContainer else {
                throw StaffReplicaSourceSyncError.access
            }
            return try StaffWorkspaceSourceStaging.prepare(container: container, scope: context.scope,
                store: StaffWorkspaceSourceStaging.device, check: { try StaffReplicaSourceDependencies.verify(context) })
        }, request: { try await GunnAireBackendService.staffReplicaSourceRequest(path: $0, method: $1, body: $2) },
              store: StaffWorkspaceSourceStaging.device)
    }
}

struct StaffWorkspacePublicationSummary {
    let conflicts: [StaffWorkspacePublicationConflict]
    let waitingForCloudKit: Int
    let hasMore: Bool
    let lastConfirmedAt: Date?
    let preparedStage: StaffWorkspaceSourceJournal
    var message: String {
        if !conflicts.isEmpty { return "\(conflicts.count) company record\(conflicts.count == 1 ? " needs" : "s need") owner review." }
        if waitingForCloudKit > 0 { return "Waiting for this device's company iCloud records to catch up." }
        return hasMore ? "Saving the company workspace copy…" : "Company workspace copy is up to date."
    }
}

/// Durable owner-source publication, not a staff projection or CloudKit import.
/// The cache is only an optimization: every use is fenced by the live server.
@MainActor final class StaffWorkspacePublicationCoordinator {
    static let shared = StaffWorkspacePublicationCoordinator(dependencies: .live)
    private let dependencies: StaffWorkspacePublicationDependencies
    private var running = false
    private struct Snapshot {
        let scope: StaffReplicaSourceScope
        let stamp: CompanyWorkspaceOperationStamp
        var sequence: Int
        var records: [StaffWorkspacePublishedRecord]
    }
    private var cache: Snapshot?
    init(dependencies: StaffWorkspacePublicationDependencies) { self.dependencies = dependencies }
    static func key(_ scope: StaffReplicaSourceScope) -> String { "full-owner-publication-v1\n" + scope.key }
    func clearCache() { cache = nil }

    private func load(_ context: StaffReplicaSourceContext) throws -> StaffWorkspacePublicationJournal {
        try dependencies.check(context)
        do {
            guard let bytes = try dependencies.store.read(Self.key(context.scope)) else { return .init(scope: context.scope) }
            let journal = try StaffWorkspacePublicationContract.decode(StaffWorkspacePublicationJournal.self, from: bytes,
                maximum: StaffWorkspacePublicationContract.maximumScanBytes)
            try journal.validate(context.scope)
            return journal
        } catch { throw StaffReplicaSourceSyncError.storage }
    }
    private func save(_ journal: StaffWorkspacePublicationJournal, _ context: StaffReplicaSourceContext) throws {
        try dependencies.check(context)
        do {
            try journal.validate(context.scope)
            let data = try StaffWorkspacePublicationContract.encode(journal)
            guard data.count <= StaffWorkspacePublicationContract.maximumScanBytes - 64 else { throw StaffReplicaSourceSyncError.storage }
            try dependencies.store.write(Self.key(context.scope), data)
        } catch { throw StaffReplicaSourceSyncError.storage }
    }
    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         context: StaffReplicaSourceContext) async throws -> Data {
        try dependencies.check(context)
        guard StaffWorkspacePublicationTransportPolicy.allows(path: path, method: method, body: body) else {
            throw StaffReplicaSourceSyncError.invalid
        }
        let data = try await dependencies.request(path, method, body)
        try dependencies.check(context)
        guard data.count <= StaffWorkspacePublicationContract.maximumResponseBytes else { throw StaffReplicaSourceSyncError.invalid }
        return data
    }
    private func page(_ context: StaffReplicaSourceContext, sequence: Int?, after: String?) async throws -> (StaffWorkspacePublicationPage, Int) {
        let bytes = try await request(StaffWorkspacePublicationTransportPolicy.path(scope: context.scope, sequence: sequence, after: after), context: context)
        let page = try StaffWorkspacePublicationContract.decode(StaffWorkspacePublicationPage.self, from: bytes)
        try page.validate(context.scope, sequence: sequence, after: after)
        return (page, bytes.count)
    }
    private func verifyFirstPage(_ first: StaffWorkspacePublicationPage, snapshot: Snapshot) throws {
        let count = first.records.count
        guard first.sequence == snapshot.sequence, first.records == Array(snapshot.records.prefix(count)),
              (snapshot.records.isEmpty || count > 0),
              first.nextCursor == (snapshot.records.count > count ? first.records.last?.key : nil) else {
            throw StaffReplicaSourceSyncError.invalid
        }
    }
    private func read(_ context: StaffReplicaSourceContext) async throws -> Snapshot {
        if let cache, cache.scope == context.scope, cache.stamp == context.stamp {
            let (first, _) = try await page(context, sequence: cache.sequence, after: nil)
            try verifyFirstPage(first, snapshot: cache)
            return cache
        }
        cache = nil
        var records: [StaffWorkspacePublishedRecord] = [], sequence: Int?, after: String?, total = 0
        repeat {
            let (value, size) = try await page(context, sequence: sequence, after: after)
            total += size
            guard total <= StaffWorkspacePublicationContract.maximumScanBytes else { throw StaffReplicaSourceSyncError.invalid }
            records += value.records; sequence = value.sequence; after = value.nextCursor
            guard records.count <= StaffWorkspacePublicationContract.maximumRecords else { throw StaffReplicaSourceSyncError.invalid }
        } while after != nil
        let (first, _) = try await page(context, sequence: sequence, after: nil)
        let snapshot = Snapshot(scope: context.scope, stamp: context.stamp, sequence: first.sequence, records: records)
        // A byte-limited page can contain fewer than 100 large/escaped records.
        try verifyFirstPage(first, snapshot: snapshot)
        cache = snapshot
        return snapshot
    }

    /// Replays the *original bytes* before any capture, read, or new operation.
    @discardableResult private func recover(_ journal: inout StaffWorkspacePublicationJournal,
                                            context: StaffReplicaSourceContext) async throws -> StaffWorkspacePublicationReceipt? {
        guard let pending = journal.pending else { return nil }
        let batch = try pending.batch(context.scope)
        let data: Data
        do {
            data = try await request(StaffWorkspacePublicationTransportPolicy.root, method: "POST", body: pending.body, context: context)
        } catch let rejection as StaffReplicaSourceRejected {
            try dependencies.check(context)
            guard ["source_changed", "record_changed", "deletion_changed"].contains(rejection.code), journal.rejected.count < 1000 else {
                throw StaffReplicaSourceSyncError.invalid
            }
            var archived = journal
            archived.rejected.append(pending); archived.pending = nil
            try save(archived, context); journal = archived
            throw StaffReplicaSourceSyncError.sourceChanged
        }
        let receipt = try StaffWorkspacePublicationContract.decode(StaffWorkspacePublicationReceipt.self, from: data)
        try receipt.validate(batch)
        var acknowledged = journal
        for change in batch.changes {
            let digest: String
            if change.action == "delete" {
                guard let previous = pending.previous[change.key] else { throw StaffReplicaSourceSyncError.storage }
                digest = previous.fieldsDigest
            } else { digest = try StaffWorkspacePublicationContract.digest(change.fields) }
            acknowledged.baseline[change.key] = .init(key: change.key, revision: change.expectedRevision + 1,
                deleted: change.action == "delete", fieldsDigest: digest)
            acknowledged.decisions[change.key] = nil
        }
        acknowledged.pending = nil; acknowledged.lastConfirmedAt = dependencies.now()
        try save(acknowledged, context) // Do not advance memory/cache before durable local acknowledgement.
        journal = acknowledged
        updateCache(batch, receipt: receipt, context: context)
        return receipt
    }
    private func updateCache(_ batch: StaffWorkspacePublicationBatch, receipt: StaffWorkspacePublicationReceipt,
                             context: StaffReplicaSourceContext) {
        guard var snapshot = cache, snapshot.scope == context.scope, snapshot.stamp == context.stamp,
              snapshot.sequence == batch.expectedSequence, receipt.currentSequence == receipt.sequence else { cache = nil; return }
        var records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.key, $0) })
        for change in batch.changes {
            let fields: [String: StaffWorkspaceValue]
            if change.action == "delete" {
                guard let old = records[change.key] else { cache = nil; return }; fields = old.fields
            } else { fields = change.fields }
            records[change.key] = .init(companyID: batch.companyID, environment: batch.environment, replicaID: batch.replicaID,
                schema: batch.schema, schemaDigest: batch.schemaDigest, kind: change.kind, id: change.id,
                revision: change.expectedRevision + 1, deleted: change.action == "delete", fields: fields)
        }
        snapshot.records = records.values.sorted { $0.key < $1.key }; snapshot.sequence = receipt.sequence
        cache = snapshot
    }

    func synchronize(_ context: StaffReplicaSourceContext) async throws -> StaffWorkspacePublicationSummary {
        guard !running else { throw StaffReplicaSourceSyncError.unavailable }
        let lockKey = Self.key(context.scope)
        let lock = try SharedTimeMutationGate.begin(lockKey)
        defer { SharedTimeMutationGate.finish(lockKey, id: lock) }
        running = true; defer { running = false }
        do {
            try dependencies.check(context)
            try StaffWorkspacePublicationContract.validateCatalog()
            var journal = try load(context)
            try await recover(&journal, context: context)
            let stage = try dependencies.prepare(context)
            try dependencies.check(context)
            var snapshot = try await read(context)
            let plan = try StaffWorkspacePublicationPlan.reconcile(stage: stage, journal: &journal, remote: snapshot.records)
            try save(journal, context)
            var offset = 0
            // Bound foreground work without rescanning the entire company for
            // each batch. The next pass re-captures local edits and fences cache.
            for _ in 0..<8 where offset < plan.changes.count {
                var selected: [StaffWorkspacePublicationChange] = []
                let operation = UUID()
                for change in plan.changes.dropFirst(offset).prefix(100) {
                    let batch = StaffWorkspacePublicationBatch(scope: context.scope, sequence: snapshot.sequence,
                        changes: selected + [change], operation: operation)
                    if try StaffWorkspacePublicationContract.encode(batch).count > StaffWorkspacePublicationContract.maximumRequestBytes { break }
                    selected.append(change)
                }
                guard !selected.isEmpty else { throw StaffReplicaSourceSyncError.invalid }
                let batch = StaffWorkspacePublicationBatch(scope: context.scope, sequence: snapshot.sequence, changes: selected, operation: operation)
                let remotes = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.key, $0) })
                var previous: [String: StaffWorkspacePublicationFingerprint] = [:]
                for change in selected where change.expectedRevision > 0 {
                    guard let original = remotes[change.key] else { throw StaffReplicaSourceSyncError.invalid }
                    previous[change.key] = try .init(original)
                }
                journal.pending = .init(body: try StaffWorkspacePublicationContract.encode(batch), previous: previous)
                try save(journal, context) // Persist identity and exact request before the first POST.
                try await recover(&journal, context: context)
                offset += selected.count
                guard let updated = cache else { break } // Another owner advanced after our accepted operation.
                snapshot = updated
            }
            return .init(conflicts: plan.conflicts, waitingForCloudKit: plan.waitingForCloudKit,
                hasMore: !plan.changes.isEmpty, lastConfirmedAt: journal.lastConfirmedAt, preparedStage: stage)
        } catch { cache = nil; throw error }
    }

    /// The caller must perform its core capture in the same synchronous actor
    /// segment. A saved edit arriving during our earlier network awaits cannot
    /// become newer staff facts ahead of its full owner-source publication.
    func matchesCurrent(_ original: StaffWorkspaceSourceJournal, context: StaffReplicaSourceContext) throws -> Bool {
        guard !running, original.scope == context.scope else { throw StaffReplicaSourceSyncError.access }
        let key = Self.key(context.scope), lock = try SharedTimeMutationGate.begin(key)
        defer { SharedTimeMutationGate.finish(key, id: lock) }
        try dependencies.check(context)
        let current = try dependencies.prepare(context)
        try dependencies.check(context)
        try current.validate(context.scope)
        return current == original
    }

    func approve(_ conflict: StaffWorkspacePublicationConflict, context: StaffReplicaSourceContext) throws {
        guard !running, conflict.local != nil || conflict.deletion else { throw StaffReplicaSourceSyncError.invalid }
        let lockKey = Self.key(context.scope)
        let lock = try SharedTimeMutationGate.begin(lockKey)
        defer { SharedTimeMutationGate.finish(lockKey, id: lock) }
        try dependencies.check(context)
        try conflict.remote.validate(context.scope)
        if let local = conflict.local {
            guard StaffWorkspaceHistory.key(local) == conflict.id else { throw StaffReplicaSourceSyncError.invalid }
            try StaffWorkspacePublicationContract.validate(local)
        }
        var journal = try load(context)
        guard journal.pending == nil else { throw StaffReplicaSourceSyncError.unavailable }
        journal.decisions[conflict.id] = try .init(local: conflict.local, remote: conflict.remote)
        try save(journal, context)
        // The next sync must still compare both exact versions before writing.
    }
}
