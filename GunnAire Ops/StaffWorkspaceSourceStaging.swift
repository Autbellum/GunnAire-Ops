import Foundation
import SwiftData
import CryptoKit

/// This is an encrypted owner-only preparation journal, not a staff payload,
/// membership grant, server operation or full-workspace delivery receipt.
nonisolated struct StaffWorkspaceSourceJournal: Codable, Equatable {
    let version: Int
    let scope: StaffReplicaSourceScope
    let records: [StaffWorkspaceModelRecord]
    let cursor: StaffWorkspaceHistoryCursor?
    let deletionKeys: [String]

    func validate(_ expected: StaffReplicaSourceScope) throws {
        let kinds = Set(StaffWorkspaceModelCatalog.all.map(\.kind))
        guard version == 1, scope == expected, deletionKeys.count <= 100_000,
              deletionKeys == Set(deletionKeys).sorted(),
              cursor != nil || deletionKeys.isEmpty,
              records.map(StaffWorkspaceHistory.key) == records.map(StaffWorkspaceHistory.key).sorted(),
              Set(deletionKeys).isDisjoint(with: records.map(StaffWorkspaceHistory.key)) else {
            throw StaffReplicaSourceSyncError.storage
        }
        for key in deletionKeys {
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, kinds.contains(String(parts[0])),
                  let id = UUID(uuidString: String(parts[1])), id.uuidString.lowercased() == parts[1] else {
                throw StaffReplicaSourceSyncError.storage
            }
        }
        if let cursor { _ = try cursor.validate(storeUUID: expected.storeUUID) }
        _ = try StaffWorkspaceRelationshipGraph.validate(records)
    }

    static func decode(_ data: Data, scope: StaffReplicaSourceScope) throws -> Self {
        guard data.count <= 64 * 1024 * 1024 else { throw StaffReplicaSourceSyncError.storage }
        let journal = try JSONDecoder().decode(Self.self, from: data)
        let original = try JSONSerialization.jsonObject(with: data)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(journal))
        guard try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys]) else { throw StaffReplicaSourceSyncError.storage }
        try journal.validate(scope)
        return journal
    }
}

@MainActor enum StaffWorkspaceSourceStaging {
    nonisolated static func key(_ scope: StaffReplicaSourceScope) -> String { "full-owner-staging-v1\n" + scope.key }

    /// The 32-byte owner-workspace key from what the keychain holds: the raw
    /// bytes this build stores, or the JSON-encoded `Data` (a quoted base64
    /// string) that builds up to 2026091616 stored through `saveCodable`.
    /// Anything else is treated as a corrupt entry, never as a new key, so an
    /// existing encrypted journal cannot become unreadable by a key reset.
    nonisolated static func ownerKey(fromStored stored: Data) -> Data? {
        if stored.count == 32 { return stored }
        if let decoded = try? JSONDecoder().decode(Data.self, from: stored), decoded.count == 32 { return decoded }
        return nil
    }

    static var device: SharedTimeLocalStore {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw StaffReplicaSourceSyncError.storage }, write: { _, _ in throw StaffReplicaSourceSyncError.storage })
        }
        return .encrypted(directory: root.appendingPathComponent("StaffWorkspaceOwner-v1", isDirectory: true), maximumBytes: 64 * 1024 * 1024) { create in
            let account = "StaffWorkspaceOwnerEncryption-v1"
            if let stored = try KeychainStore.loadData(account: account) {
                guard let bytes = ownerKey(fromStored: stored) else { throw StaffReplicaSourceSyncError.storage }
                // Builds before 2026091617 wrote the key through the Codable API,
                // which JSON-encodes `Data`. Rewrite it raw once; a failed rewrite
                // is retried next time and never blocks the read.
                if bytes != stored { try? KeychainStore.saveData(bytes, account: account) }
                return bytes
            }
            guard create else { throw StaffReplicaSourceSyncError.storage }
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveData(bytes, account: account); return bytes
        }
    }

    /// Synchronous staging on the main actor, kept for the tests and any
    /// caller already holding the main thread.
    @discardableResult static func prepare(container: ModelContainer, scope: StaffReplicaSourceScope,
                                          store: SharedTimeLocalStore, check: () throws -> Void) throws -> StaffWorkspaceSourceJournal {
        try check()
        let previous = try readPrevious(store, scope: scope)
        let capture = try StaffWorkspaceHistory.capture(container: container, after: previous?.cursor, storeUUID: scope.storeUUID)
        let journal = try assemble(capture, previous: previous, scope: scope)
        try check()
        try persist(journal, previous: previous, store: store, scope: scope)
        return journal
    }

    /// The same staging with the journal read, the 32-kind capture, the
    /// validation and the encrypted write on a background task. The session
    /// checks and the unsaved-changes fences stay on the main actor. The
    /// owner-workspace publication runs this every minute, twice per pass.
    static func prepareOffMain(container: ModelContainer, scope: StaffReplicaSourceScope,
                               store: SharedTimeLocalStore, check: () throws -> Void) async throws -> StaffWorkspaceSourceJournal {
        try check()
        guard !container.mainContext.hasChanges else { throw StaffReplicaSourceError.unsaved }
        let (previous, journal) = try await Task.detached(priority: .utility) { () throws -> (StaffWorkspaceSourceJournal?, StaffWorkspaceSourceJournal) in
            let previous = try readPrevious(store, scope: scope)
            let capture = try StaffWorkspaceHistory.captureBodyForStaging(container: container, after: previous?.cursor, storeUUID: scope.storeUUID)
            return (previous, try assemble(capture, previous: previous, scope: scope))
        }.value
        guard !container.mainContext.hasChanges else { throw StaffReplicaSourceError.unsaved }
        try check()
        guard journal != previous else { return journal }
        try await Task.detached(priority: .utility) {
            try persist(journal, previous: previous, store: store, scope: scope)
        }.value
        return journal
    }

    nonisolated private static func readPrevious(_ store: SharedTimeLocalStore, scope: StaffReplicaSourceScope) throws -> StaffWorkspaceSourceJournal? {
        do { return try store.read(key(scope)).map { try StaffWorkspaceSourceJournal.decode($0, scope: scope) } }
        catch { throw StaffReplicaSourceSyncError.storage }
    }

    nonisolated private static func assemble(_ capture: StaffWorkspaceHistoryCapture, previous: StaffWorkspaceSourceJournal?,
                                             scope: StaffReplicaSourceScope) throws -> StaffWorkspaceSourceJournal {
        var deletions = Set(previous?.deletionKeys ?? []).union(capture.deletions)
        deletions.subtract(capture.records.map(StaffWorkspaceHistory.key))
        let journal = StaffWorkspaceSourceJournal(version: 1, scope: scope, records: capture.records,
                                                  cursor: capture.cursor, deletionKeys: deletions.sorted())
        try journal.validate(scope)
        return journal
    }

    /// Snapshot, original tombstones and cursor move together, or not at
    /// all. Until a full-domain protocol acknowledges them, retain deletions
    /// across every relaunch; the six-kind ledger cannot acknowledge these.
    nonisolated private static func persist(_ journal: StaffWorkspaceSourceJournal, previous: StaffWorkspaceSourceJournal?,
                                            store: SharedTimeLocalStore, scope: StaffReplicaSourceScope) throws {
        guard journal != previous else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try store.write(key(scope), encoder.encode(journal))
        } catch { throw StaffReplicaSourceSyncError.storage }
    }
}
