import Foundation
import SwiftData
import CryptoKit

/// This is an encrypted owner-only preparation journal, not a staff payload,
/// membership grant, server operation or full-workspace delivery receipt.
struct StaffWorkspaceSourceJournal: Codable, Equatable {
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
    static func key(_ scope: StaffReplicaSourceScope) -> String { "full-owner-staging-v1\n" + scope.key }

    static var device: SharedTimeLocalStore {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return .init(read: { _ in throw StaffReplicaSourceSyncError.storage }, write: { _, _ in throw StaffReplicaSourceSyncError.storage })
        }
        return .encrypted(directory: root.appendingPathComponent("StaffWorkspaceOwner-v1", isDirectory: true), maximumBytes: 64 * 1024 * 1024) { create in
            let account = "StaffWorkspaceOwnerEncryption-v1"
            if let bytes = try KeychainStore.loadCodable(Data.self, account: account) {
                guard bytes.count == 32 else { throw StaffReplicaSourceSyncError.storage }; return bytes
            }
            guard create else { throw StaffReplicaSourceSyncError.storage }
            let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try KeychainStore.saveCodable(bytes, account: account); return bytes
        }
    }

    @discardableResult static func prepare(container: ModelContainer, scope: StaffReplicaSourceScope,
                                          store: SharedTimeLocalStore, check: () throws -> Void) throws -> StaffWorkspaceSourceJournal {
        try check()
        let storageKey = key(scope)
        let previous: StaffWorkspaceSourceJournal?
        do { previous = try store.read(storageKey).map { try StaffWorkspaceSourceJournal.decode($0, scope: scope) } }
        catch { throw StaffReplicaSourceSyncError.storage }
        let capture = try StaffWorkspaceHistory.capture(container: container, after: previous?.cursor, storeUUID: scope.storeUUID)
        var deletions = Set(previous?.deletionKeys ?? []).union(capture.deletions)
        deletions.subtract(capture.records.map(StaffWorkspaceHistory.key))
        let journal = StaffWorkspaceSourceJournal(version: 1, scope: scope, records: capture.records,
                                                  cursor: capture.cursor, deletionKeys: deletions.sorted())
        try journal.validate(scope)
        try check()
        // Snapshot, original tombstones and cursor move together, or not at
        // all. Until a full-domain protocol acknowledges them, retain deletions
        // across every relaunch; the six-kind ledger cannot acknowledge these.
        if journal != previous {
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try store.write(storageKey, encoder.encode(journal))
            } catch { throw StaffReplicaSourceSyncError.storage }
        }
        return journal
    }
}
