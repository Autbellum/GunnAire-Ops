import Foundation

enum StaffReplicaSourceSyncError: Error, LocalizedError, Equatable {
    case invalid, history, storage, access, unavailable, sourceChanged
    var errorDescription: String? {
        switch self {
        case .invalid: "The staff preparation response needs review. Saved work was retained."
        case .history: "Saved change history could not be verified. Keep this app installed and ask for a workspace review."
        case .storage: "Staff sync recovery could not be saved. Keep this app installed and try again."
        case .access: "Verify the approved administrator and company iCloud workspace to prepare staff data."
        case .unavailable: "Staff preparation is waiting for a connection. Your saved work is retained."
        case .sourceChanged: "Newer company work arrived. Retry to reconcile it with this device's saved work."
        }
    }
}

extension StaffReplicaCoreRecord { var key: String { kind + ":" + id } }

struct StaffReplicaSourceScope: Codable, Equatable {
    let backendOrigin: String
    let actorEmail: String
    let binding: CompanyCloudKitBinding
    let storeUUID: String
    var key: String {
        ["staff-source-v1", backendOrigin, actorEmail, binding.companyID.uuidString.lowercased(), binding.environment,
         binding.replicaID.uuidString.lowercased(), binding.cloudAccountHash, storeUUID].joined(separator: "\n")
    }
}

struct StaffReplicaSourceRemoteRecord: Codable, Equatable {
    let companyID: UUID
    let environment: String
    let replicaID: UUID
    let kind: String
    let id: String
    let revision: Int
    let deleted: Bool
    let fields: [String: StaffReplicaScalar]
    var key: String { kind + ":" + id }
    var live: StaffReplicaCoreRecord? { deleted ? nil : .init(kind: kind, id: id, fields: fields) }
    func validate(_ scope: StaffReplicaSourceScope) throws {
        guard companyID == scope.binding.companyID, environment == scope.binding.environment, replicaID == scope.binding.replicaID,
              StaffReplicaCoreSource.recordKinds.contains(kind), CloudKitStaffSetupPolicy.canonicalID(id),
              (1..<2_147_483_647).contains(revision), try JSONEncoder().encode(fields).count <= 64 * 1024 else {
            throw StaffReplicaSourceSyncError.invalid
        }
    }
}

struct StaffReplicaSourcePage: Codable {
    let schema: String
    let companyID: UUID
    let environment: String
    let replicaID: UUID
    let sequence: Int
    let authorizationSequence: Int
    let records: [StaffReplicaSourceRemoteRecord]
    let nextCursor: String?
    func validate(_ scope: StaffReplicaSourceScope, sequence expected: Int?, after: String?) throws {
        guard schema == StaffReplicaCoreSource.schemaVersion, companyID == scope.binding.companyID,
              environment == scope.binding.environment, replicaID == scope.binding.replicaID,
              (0..<2_147_483_647).contains(sequence), (0...sequence).contains(authorizationSequence),
              expected == nil || expected == sequence, records.count <= 100,
              sequence > 0 || records.isEmpty,
              records.map(\.key) == records.map(\.key).sorted(), Set(records.map(\.key)).count == records.count,
              records.allSatisfy({ $0.key > (after ?? "") }),
              nextCursor == nil || (records.count == 100 && nextCursor == records.last?.key) else { throw StaffReplicaSourceSyncError.invalid }
        try records.forEach { try $0.validate(scope) }
    }
}

struct StaffReplicaSourceChange: Codable, Equatable {
    let kind: String
    let id: String
    let expectedRevision: Int
    let action: String
    let fields: [String: StaffReplicaScalar]
    var key: String { kind + ":" + id }
}

struct StaffReplicaSourceBatch: Codable, Equatable {
    let companyID: String
    let environment: String
    let schema: String
    let operationID: String
    let expectedSequence: Int
    let changes: [StaffReplicaSourceChange]
    init(scope: StaffReplicaSourceScope, sequence: Int, changes: [StaffReplicaSourceChange], operation: UUID = UUID()) {
        companyID = scope.binding.companyID.uuidString.lowercased(); environment = scope.binding.environment
        schema = StaffReplicaCoreSource.schemaVersion; operationID = operation.uuidString.lowercased()
        expectedSequence = sequence; self.changes = changes
    }
    func validate(_ scope: StaffReplicaSourceScope) throws {
        guard companyID == scope.binding.companyID.uuidString.lowercased(), environment == scope.binding.environment,
              schema == StaffReplicaCoreSource.schemaVersion, CloudKitStaffSetupPolicy.canonicalID(operationID),
              (0..<2_147_483_646).contains(expectedSequence), (1...100).contains(changes.count),
              Set(changes.map(\.key)).count == changes.count else { throw StaffReplicaSourceSyncError.invalid }
        for change in changes {
            guard StaffReplicaCoreSource.recordKinds.contains(change.kind), CloudKitStaffSetupPolicy.canonicalID(change.id),
                  (0..<2_147_483_646).contains(change.expectedRevision), ["upsert", "delete", "restore"].contains(change.action),
                  change.action != "delete" || change.fields.isEmpty,
                  change.action == "upsert" || change.expectedRevision > 0 else { throw StaffReplicaSourceSyncError.invalid }
        }
    }
}

struct StaffReplicaSourceReceipt: Codable {
    struct Change: Codable, Equatable { let kind: String; let id: String; let revision: Int; let deleted: Bool }
    let operationID: String
    let companyID: UUID
    let environment: String
    let replicaID: UUID
    let schema: String
    let sequence: Int
    let currentSequence: Int
    let changes: [Change]
    func validate(_ batch: StaffReplicaSourceBatch, scope: StaffReplicaSourceScope) throws {
        guard operationID == batch.operationID, companyID == scope.binding.companyID, environment == scope.binding.environment,
              replicaID == scope.binding.replicaID, schema == batch.schema, sequence == batch.expectedSequence + 1,
              currentSequence >= sequence, currentSequence < 2_147_483_647,
              changes == batch.changes.map({ .init(kind: $0.kind, id: $0.id, revision: $0.expectedRevision + 1, deleted: $0.action == "delete") }) else {
            throw StaffReplicaSourceSyncError.invalid
        }
    }
}

/// A decision approves exact compared values, not whatever happens to be on the
/// server by the time a request runs. Changed values invalidate the decision.
struct StaffReplicaSourceDecision: Codable, Equatable {
    let local: StaffReplicaCoreRecord?
    let remote: StaffReplicaSourceRemoteRecord
}
struct StaffReplicaSourceConflict: Identifiable, Equatable {
    let local: StaffReplicaCoreRecord?
    let remote: StaffReplicaSourceRemoteRecord
    let deletion: Bool
    var referenceNames: [String: String] = [:]
    var id: String { remote.key }
    var title: String {
        if case .text(let name) = local?.fields["name"] ?? remote.fields["name"] { return name }
        if case .text(let title) = local?.fields["eventTitle"] ?? remote.fields["eventTitle"] { return title }
        return remote.kind.capitalized
    }
}

struct StaffReplicaSourceJournal: Codable {
    let scope: StaffReplicaSourceScope
    var token: Data?
    var snapshot: StaffReplicaCoreSource?
    var deletions: Set<String> = []
    var baseline: [String: StaffReplicaSourceRemoteRecord] = [:]
    var pending: StaffReplicaSourceBatch?
    var rejected: [StaffReplicaSourceBatch] = []
    var decisions: [String: StaffReplicaSourceDecision] = [:]
    var lastConfirmedAt: Date?
}

struct StaffReplicaSourcePlan {
    let changes: [StaffReplicaSourceChange]
    let conflicts: [StaffReplicaSourceConflict]
    let waitingForCloudKit: Int

    static func reconcile(journal: inout StaffReplicaSourceJournal, remote: [StaffReplicaSourceRemoteRecord]) throws -> Self {
        guard let source = journal.snapshot, source.schema == StaffReplicaCoreSource.schemaVersion,
              source.coverage == StaffReplicaCoreSource.recordKinds, source.records.count <= 20_000,
              Set(source.records.map(\.key)).count == source.records.count,
              Set(remote.map(\.key)).count == remote.count else { throw StaffReplicaSourceSyncError.invalid }
        let locals = Dictionary(uniqueKeysWithValues: source.records.map { ($0.key, $0) })
        let remotes = Dictionary(uniqueKeysWithValues: remote.map { ($0.key, $0) })
        var referenceNames: [String: String] = [:]
        for value in remoteRecordsForLabels(remote: remotes) + source.records {
            if case .text(let name) = value.fields["name"] ?? value.fields["eventTitle"] { referenceNames[value.id] = name }
        }
        var changes: [StaffReplicaSourceChange] = [], conflicts: [StaffReplicaSourceConflict] = []
        var waiting = 0
        for key in Set(locals.keys).union(remotes.keys).union(journal.deletions).union(journal.baseline.keys).sorted() {
            let local = locals[key], remote = remotes[key], base = journal.baseline[key]
            if let remote { try remote.validate(journal.scope) }
            if let remote, local == remote.live, local != nil || remote.deleted {
                journal.baseline[key] = remote; journal.decisions[key] = nil
                journal.deletions.remove(key); continue
            }
            if remote == nil {
                if base != nil { throw StaffReplicaSourceSyncError.invalid } // Retained server records cannot simply disappear.
                if let local {
                    changes.append(.init(kind: local.kind, id: local.id, expectedRevision: 0, action: "upsert", fields: local.fields))
                } else { journal.deletions.remove(key) }
                continue
            }
            guard let remote else { continue }
            let deleting = local == nil && journal.deletions.contains(key)
            let approved = journal.decisions[key] == .init(local: local, remote: remote)
            if local == nil && !deleting { waiting += 1; continue } // Absence is never a deletion.
            if approved || (base == remote && !remote.deleted) {
                changes.append(.init(kind: remote.kind, id: remote.id, expectedRevision: remote.revision,
                    action: deleting ? "delete" : (remote.deleted ? "restore" : "upsert"), fields: local?.fields ?? [:]))
            } else if local == base?.live && !deleting && base != nil {
                waiting += 1 // Wait for the owner's CloudKit data, not a blind import of this limited schema.
            } else {
                conflicts.append(.init(local: local, remote: remote, deletion: deleting, referenceNames: referenceNames))
            }
        }
        return .init(changes: changes, conflicts: conflicts, waitingForCloudKit: waiting)
    }
    private static func remoteRecordsForLabels(remote: [String: StaffReplicaSourceRemoteRecord]) -> [StaffReplicaCoreRecord] {
        remote.values.map { .init(kind: $0.kind, id: $0.id, fields: $0.fields) }
    }
}

enum StaffReplicaSourceTransportPolicy {
    static let root = "/api/workspace/replica-records"
    static func path(scope: StaffReplicaSourceScope, sequence: Int? = nil, after: String? = nil) -> String {
        var path = root + "?companyID=" + scope.binding.companyID.uuidString.lowercased() + "&environment=" + scope.binding.environment
        if let sequence { path += "&sequence=\(sequence)" }
        if let after { path += "&after=" + after }
        return path
    }
    static func allows(path: String, method: String, body: Data?) -> Bool {
        if method == "POST" { return path == root && body.map { !$0.isEmpty && $0.count <= 2 * 1024 * 1024 } == true }
        guard method == "GET", body == nil, let url = URLComponents(string: path), url.scheme == nil, url.host == nil,
              url.fragment == nil, url.percentEncodedPath == root, !path.contains("%"),
              let query = url.queryItems, Set(query.map(\.name)).count == query.count else { return false }
        let values = Dictionary(uniqueKeysWithValues: query.compactMap { value in value.value.map { (value.name, $0) } })
        guard values.count == query.count, let company = values["companyID"], CloudKitStaffSetupPolicy.canonicalID(company),
              ["development", "production"].contains(values["environment"] ?? ""),
              Set(values.keys).isSubset(of: ["companyID", "environment", "sequence", "after"]) else { return false }
        if let sequence = values["sequence"] {
            guard let number = Int(sequence), (0..<2_147_483_647).contains(number), String(number) == sequence else { return false }
        }
        if let after = values["after"] {
            let parts = after.split(separator: ":")
            guard values["sequence"] != nil, parts.count == 2, StaffReplicaCoreSource.recordKinds.contains(String(parts[0])),
                  CloudKitStaffSetupPolicy.canonicalID(String(parts[1])) else { return false }
        }
        return true
    }
}
