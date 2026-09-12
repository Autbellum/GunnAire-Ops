import Foundation

/// Unfinished local input is not a command, receipt, or permission grant.
/// A nil input is a durable discard tombstone that fences older windows.
struct StaffWorkspaceFieldDraft: Codable, Equatable {
    var version = 1
    let snapshot: StaffWorkspaceFieldEditorSnapshot
    let commandID: UUID
    let revision: Int
    let initial: StaffWorkspaceFieldEditorInput
    let input: StaffWorkspaceFieldEditorInput?

    func validate(plan: CloudKitStaffSharePlan) throws {
        guard version == 1, (0..<Int.max - 1).contains(revision), snapshot.planID == plan.id else {
            throw StaffReplicaDeliveryError.storage
        }
        _ = try snapshot.request(plan: plan, commandID: commandID, value: snapshot.candidate.currentValue)
        for raw in [initial, input].compactMap({ $0 }) {
            // Invalid/incomplete scalars are legitimate drafts, but not unbounded data.
            guard raw.text.utf8.count <= 65_536, !raw.text.contains("\0"), raw.date.timeIntervalSinceReferenceDate.isFinite else {
                throw StaffReplicaDeliveryError.storage
            }
        }
    }
    func sameField(as other: StaffWorkspaceFieldEditorSnapshot) -> Bool {
        snapshot.scope == other.scope && snapshot.planID == other.planID &&
        snapshot.candidate.recordKind == other.candidate.recordKind &&
        snapshot.candidate.recordID == other.candidate.recordID && snapshot.candidate.fieldName == other.candidate.fieldName
    }
}

enum StaffWorkspaceFieldDraftStore {
    static func key(_ snapshot: StaffWorkspaceFieldEditorSnapshot) -> String {
        let c = snapshot.candidate
        return "staff-field-draft-v1\n" + snapshot.scope.key + "\n" + snapshot.planID.uuidString.lowercased() +
            "\n" + c.recordKind + "\n" + c.recordID + "\n" + c.fieldName
    }
    static func load(store: SharedTimeLocalStore, snapshot: StaffWorkspaceFieldEditorSnapshot,
                     plan: CloudKitStaffSharePlan) throws -> StaffWorkspaceFieldDraft? {
        guard let bytes = try store.read(key(snapshot)) else { return nil }
        let draft = try StaffWorkspacePublicationContract.decode(StaffWorkspaceFieldDraft.self, from: bytes, maximum: 262_144)
        try draft.validate(plan: plan)
        guard draft.sameField(as: snapshot) else { throw StaffReplicaDeliveryError.storage }
        return draft
    }
    static func write(store: SharedTimeLocalStore, next: StaffWorkspaceFieldDraft, expected: StaffWorkspaceFieldDraft?,
                      plan: CloudKitStaffSharePlan, check: () throws -> Void) throws {
        try check(); try next.validate(plan: plan)
        let previous = try load(store: store, snapshot: next.snapshot, plan: plan)
        if previous == next { try check(); return } // Interrupted write acknowledgement.
        guard previous == expected, next.revision == (previous.map { $0.revision + 1 } ?? 0) else {
            throw StaffReplicaDeliveryError.changed
        }
        let bytes = try StaffWorkspacePublicationContract.encode(next)
        guard bytes.count <= 262_144 else { throw StaffReplicaDeliveryError.storage }
        try check(); try store.write(key(next.snapshot), bytes); try check()
        guard try load(store: store, snapshot: next.snapshot, plan: plan) == next else { throw StaffReplicaDeliveryError.storage }
    }
}
