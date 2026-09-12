import Foundation

/// Small, exact-content baselines avoid keeping a second copy of every HR,
/// financial and document field in the publication journal.
struct StaffWorkspacePublicationFingerprint: Codable, Equatable {
    let key: String
    let revision: Int
    let deleted: Bool
    let fieldsDigest: String
    init(_ record: StaffWorkspacePublishedRecord) throws {
        key = record.key; revision = record.revision; deleted = record.deleted
        fieldsDigest = try StaffWorkspacePublicationContract.digest(record.fields)
    }
    init(key: String, revision: Int, deleted: Bool, fieldsDigest: String) {
        self.key = key; self.revision = revision; self.deleted = deleted; self.fieldsDigest = fieldsDigest
    }
    func validate() throws {
        guard StaffWorkspacePublicationContract.validKey(key), (1..<2_147_483_647).contains(revision),
              fieldsDigest.count == 64, fieldsDigest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw StaffReplicaSourceSyncError.storage
        }
    }
}

struct StaffWorkspacePublicationDecision: Codable, Equatable {
    let localDigest: String?
    let remote: StaffWorkspacePublicationFingerprint
    init(local: StaffWorkspaceModelRecord?, remote: StaffWorkspacePublishedRecord) throws {
        localDigest = try local.map { try StaffWorkspacePublicationContract.digest($0) }
        self.remote = try .init(remote)
    }
}

struct StaffWorkspacePublicationConflict: Identifiable, Equatable {
    let local: StaffWorkspaceModelRecord?
    let remote: StaffWorkspacePublishedRecord
    let deletion: Bool
    var id: String { remote.key }
    var title: String {
        for name in ["name", "eventTitle", "title", "invoiceNumber", "estimateNumber", "documentNumber", "subject"] {
            if case .text(let value) = (local?.fields ?? remote.fields)[name], !value.isEmpty {
                return String(value.prefix(160))
            }
        }
        return remote.kind.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}

struct StaffWorkspacePublicationJournal: Codable {
    let version: Int
    let scope: StaffReplicaSourceScope
    var baseline: [String: StaffWorkspacePublicationFingerprint] = [:]
    var pending: StaffWorkspacePublicationPending?
    var rejected: [StaffWorkspacePublicationPending] = []
    var decisions: [String: StaffWorkspacePublicationDecision] = [:]
    var lastConfirmedAt: Date?
    init(scope: StaffReplicaSourceScope) { version = 1; self.scope = scope }
    func validate(_ expected: StaffReplicaSourceScope) throws {
        guard version == 1, scope == expected, baseline.count <= StaffWorkspacePublicationContract.maximumRecords,
              rejected.count <= 1000, decisions.count <= 1000,
              lastConfirmedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            throw StaffReplicaSourceSyncError.storage
        }
        for (key, value) in baseline {
            guard key == value.key else { throw StaffReplicaSourceSyncError.storage }; try value.validate()
        }
        for (key, decision) in decisions {
            guard key == decision.remote.key else { throw StaffReplicaSourceSyncError.storage }
            try decision.remote.validate()
            if let hash = decision.localDigest {
                guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw StaffReplicaSourceSyncError.storage }
            }
        }
        var ids = Set<String>()
        for original in rejected + (pending.map { [$0] } ?? []) {
            let batch = try original.batch(scope)
            guard ids.insert(batch.operationID).inserted else { throw StaffReplicaSourceSyncError.storage }
        }
    }
}

struct StaffWorkspacePublicationPlan {
    let changes: [StaffWorkspacePublicationChange]
    let conflicts: [StaffWorkspacePublicationConflict]
    let waitingForCloudKit: Int
    static func reconcile(stage: StaffWorkspaceSourceJournal, journal: inout StaffWorkspacePublicationJournal,
                          remote: [StaffWorkspacePublishedRecord]) throws -> Self {
        try stage.validate(journal.scope)
        guard remote.count <= StaffWorkspacePublicationContract.maximumRecords,
              Set(remote.map(\.key)).count == remote.count else { throw StaffReplicaSourceSyncError.invalid }
        try remote.forEach { try $0.validate(journal.scope) }
        let locals = Dictionary(uniqueKeysWithValues: stage.records.map { (StaffWorkspaceHistory.key($0), $0) })
        let remotes = Dictionary(uniqueKeysWithValues: remote.map { ($0.key, $0) })
        let deleted = Set(stage.deletionKeys)
        var changes: [StaffWorkspacePublicationChange] = [], conflicts: [StaffWorkspacePublicationConflict] = []
        var waiting = 0
        for key in Set(locals.keys).union(remotes.keys).union(journal.baseline.keys).union(deleted).sorted() {
            let local = locals[key], remote = remotes[key], base = journal.baseline[key]
            guard let remote else {
                guard base == nil else { throw StaffReplicaSourceSyncError.invalid } // Retained originals cannot vanish.
                if let local {
                    changes.append(.init(kind: local.kind, id: local.id.uuidString.lowercased(), expectedRevision: 0,
                                         action: "upsert", fields: local.fields))
                }
                continue
            }
            let fingerprint = try StaffWorkspacePublicationFingerprint(remote)
            if local == remote.live, local != nil || remote.deleted {
                journal.baseline[key] = fingerprint; journal.decisions[key] = nil; continue
            }
            let deleting = local == nil && deleted.contains(key)
            if local == nil && !deleting { waiting += 1; continue } // Absence never invents a deletion.
            let approved = try journal.decisions[key] == StaffWorkspacePublicationDecision(local: local, remote: remote)
            if approved || (base == fingerprint && !remote.deleted) {
                changes.append(.init(kind: remote.kind, id: remote.id, expectedRevision: remote.revision,
                    action: deleting ? "delete" : (remote.deleted ? "restore" : "upsert"), fields: local?.fields ?? [:]))
            } else if let local, let base, !base.deleted, !remote.deleted, !deleting,
                      try StaffWorkspacePublicationContract.digest(local.fields) == base.fieldsDigest {
                waiting += 1 // Original CloudKit data must catch up; never import this archival source blindly.
            } else {
                conflicts.append(.init(local: local, remote: remote, deletion: deleting))
            }
        }
        return .init(changes: changes, conflicts: conflicts, waitingForCloudKit: waiting)
    }
}
