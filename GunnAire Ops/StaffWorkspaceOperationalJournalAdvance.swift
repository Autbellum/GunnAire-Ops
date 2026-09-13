import Foundation

/// Advances one already-validated stage of a staff snapshot. Does not validate
/// cloud authority or unlock a workspace: each caller must finish its existing
/// mount/role/account checks first. Retains exact predecessor bytes before the
/// current pointer changes; an interrupted write is replayable without erasing
/// field commands, drafts, mounted payloads, or prior recovery evidence.
enum StaffWorkspaceOperationalJournalAdvance {
    private struct Generation: Decodable {
        let schema: String
        let scope: CloudKitStaffSetupScope
        let planID: UUID
        let selectionID: String
        let sourceSequence: Int
        let contentSHA256: String

        func validate() throws {
            guard !schema.isEmpty, schema.utf8.count <= 128,
                  CloudKitStaffSetupPolicy.canonicalID(selectionID),
                  (1...2_147_483_647).contains(sourceSequence),
                  JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256) else {
                throw StaffReplicaDeliveryError.storage
            }
        }
    }

    static func historyKey(_ key: String, sequence: Int, selection: String) -> String {
        key + "\nprevious-generation-v1\n" + String(sequence) + "\n" + selection
    }

    static func commit<Journal: Codable & Equatable>(
        _ next: Journal, replacing previous: Journal?, key: String,
        store: SharedTimeLocalStore, check: () throws -> Void
    ) throws {
        try check()
        let encoded = try StaffWorkspacePublicationContract.encode(next)
        guard encoded.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
        // This header is intentionally a subset of the full typed journal.
        // New bytes come from Journal.encode; retained bytes must pass the
        // closed-schema Journal decoder below before a header is extracted.
        let proposed = try JSONDecoder().decode(Generation.self, from: encoded)
        try proposed.validate()
        let retained = try store.read(key)
        if let previous {
            guard let retained, retained.count <= 8192,
                  try StaffWorkspacePublicationContract.decode(Journal.self, from: retained, maximum: 8192) == previous else {
                throw StaffReplicaDeliveryError.changed
            }
            if previous == next { return }
            let original = try JSONDecoder().decode(Generation.self, from: retained)
            try original.validate()
            guard original.schema == proposed.schema, original.scope == proposed.scope,
                  original.planID == proposed.planID else { throw StaffReplicaDeliveryError.changed }
            if original.sourceSequence > proposed.sourceSequence { throw StaffReplicaDeliveryError.superseded }
            guard proposed.sourceSequence > original.sourceSequence,
                  proposed.selectionID != original.selectionID else { throw StaffReplicaDeliveryError.changed }
            let archive = historyKey(key, sequence: original.sourceSequence, selection: original.selectionID)
            try check()
            if let saved = try store.read(archive) {
                guard saved == retained else { throw StaffReplicaDeliveryError.storage }
            } else {
                try store.write(archive, retained)
            }
            try check()
            guard try store.read(archive) == retained else { throw StaffReplicaDeliveryError.storage }
        } else if retained != nil {
            throw StaffReplicaDeliveryError.changed
        }
        try check()
        // A late local change must not be overwritten by a previously read head.
        guard try store.read(key) == retained else { throw StaffReplicaDeliveryError.changed }
        try store.write(key, encoded)
        try check()
        guard try store.read(key) == encoded else { throw StaffReplicaDeliveryError.storage }
    }
}
