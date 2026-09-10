import Foundation

/// Frozen display binding. Saving may not silently adopt a newer mounted head.
struct StaffWorkspaceFieldEditorSnapshot: Equatable {
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let candidate: StaffWorkspaceOperationalCommandCandidate

    func alreadySubmitted(_ value: StaffWorkspaceValue, history: [StaffWorkspaceOperationalCommandJournal]) -> Bool {
        guard let last = history.last else { return false }
        return last.request.value == value && last.request.expectedRevision == candidate.revision
    }

    func request(plan: CloudKitStaffSharePlan, commandID: UUID, value: StaffWorkspaceValue) throws -> StaffWorkspaceOperationalCommandRequest {
        try .init(companyID: scope.company.uuidString.lowercased(), environment: scope.environment,
                  replicaID: plan.replicaID.uuidString.lowercased(), commandID: commandID, selectionID: selectionID,
                  sourceSequence: sourceSequence, contentSHA256: contentSHA256, candidate: candidate, value: value)
    }
}

/// A small encrypted pointer to the last local submission, not a replacement
/// receipt or a mutable copy of the office field. Original journals stay intact.
struct StaffWorkspaceFieldEditorReference: Codable, Equatable {
    let version: Int
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let requests: [StaffWorkspaceOperationalCommandRequest]
}

enum StaffWorkspaceFieldEditorStore {
    static func key(scope: CloudKitStaffSetupScope, plan: UUID, kind: String, recordID: String, field: String) -> String {
        "staff-field-editor-last-v1\n" + scope.key + "\n" + plan.uuidString.lowercased() + "\n" + kind + "\n" + recordID + "\n" + field
    }
    static func reference(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                          kind: String, recordID: String, field: String) throws -> StaffWorkspaceFieldEditorReference? {
        guard let bytes = try store.read(key(scope: scope, plan: plan, kind: kind, recordID: recordID, field: field)) else { return nil }
        let ref = try StaffWorkspacePublicationContract.decode(StaffWorkspaceFieldEditorReference.self, from: bytes, maximum: 2 * 1024 * 1024)
        guard ref.version == 1, ref.scope == scope, ref.planID == plan, (1...128).contains(ref.requests.count),
              Set(ref.requests.map(\.commandID)).count == ref.requests.count else {
            throw StaffReplicaDeliveryError.storage
        }
        for request in ref.requests {
            try request.validate()
            guard request.companyID == scope.company.uuidString.lowercased(), request.environment == scope.environment,
                  request.recordKind == kind, request.recordID == recordID, request.fieldName == field else { throw StaffReplicaDeliveryError.storage }
        }
        return ref
    }
    static func history(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
                        kind: String, recordID: String, field: String) throws -> [StaffWorkspaceOperationalCommandJournal] {
        let pending = try StaffWorkspaceOperationalCommandStore.listPending(store: store, scope: scope, plan: plan.id)
            .filter { $0.request.recordKind == kind && $0.request.recordID == recordID && $0.request.fieldName == field }
        var result: [StaffWorkspaceOperationalCommandJournal] = []
        if let ref = try reference(store: store, scope: scope, plan: plan.id, kind: kind, recordID: recordID, field: field) {
            for request in ref.requests {
                guard let original = try StaffWorkspaceOperationalCommandStore.load(store: store, scope: scope,
                    plan: plan.id, commandID: request.commandID) ?? pending.first(where: { $0.request.commandID == request.commandID }),
                      original.request == request else { throw StaffReplicaDeliveryError.storage }
                result.append(original)
            }
        }
        result += pending.filter { p in !result.contains { $0.request.commandID == p.request.commandID } }
        guard result.allSatisfy({ $0.request.replicaID == plan.replicaID.uuidString.lowercased() }) else { throw StaffReplicaDeliveryError.changed }
        return result
    }
    static func remember(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
                         original: StaffWorkspaceOperationalCommandJournal, check: () throws -> Void) throws {
        try check(); try original.validate(scope: scope, plan: plan.id)
        let r = original.request
        let history = try history(store: store, scope: scope, plan: plan, kind: r.recordKind, recordID: r.recordID, field: r.fieldName)
        // The global command queue is the write-ahead record. Never leave a
        // discoverability reference to a command that was not durably queued.
        guard let saved = try StaffWorkspaceOperationalCommandStore.load(store: store, scope: scope, plan: plan.id, commandID: r.commandID)
                ?? history.first(where: { $0.request.commandID == r.commandID }), saved.request == r else {
            throw StaffReplicaDeliveryError.storage
        }
        var requests = try reference(store: store, scope: scope, plan: plan.id, kind: r.recordKind, recordID: r.recordID, field: r.fieldName)?.requests ?? []
        if let prior = requests.first(where: { $0.commandID == r.commandID }) {
            guard prior == r else { throw StaffReplicaDeliveryError.changed }
            try check(); return
        }
        requests.append(r)
        while requests.count > 128 {
            // Trim only a discovery reference, never an original journal or a
            // pending update. Complete history is available from the server.
            guard let index = requests.firstIndex(where: { request in
                history.contains { $0.request == request && $0.state == "recorded" }
            }) else { throw StaffReplicaDeliveryError.storage }
            requests.remove(at: index)
        }
        let next = StaffWorkspaceFieldEditorReference(version: 1, scope: scope, planID: plan.id, requests: requests)
        let bytes = try StaffWorkspacePublicationContract.encode(next)
        guard bytes.count <= 2 * 1024 * 1024 else { throw StaffReplicaDeliveryError.storage }
        try check()
        try store.write(key(scope: scope, plan: plan.id, kind: r.recordKind, recordID: r.recordID, field: r.fieldName), bytes)
        try check()
        guard try reference(store: store, scope: scope, plan: plan.id, kind: r.recordKind, recordID: r.recordID, field: r.fieldName) == next else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}
