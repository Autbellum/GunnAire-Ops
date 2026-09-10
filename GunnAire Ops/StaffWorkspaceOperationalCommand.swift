import Foundation

/// Staff operational field-command path after semantic acceptance.
///
/// Journals command intent + server receipt only. Never mutates mounted content
/// bytes, never flips `operationalWorkspaceReady`, and is not ModelContext import.
struct StaffWorkspaceOperationalCommandCandidate: Equatable {
    let recordKind: String
    let recordID: String
    let revision: Int
    let fieldName: String
    let currentValue: StaffWorkspaceValue
}

struct StaffWorkspaceOperationalCommandRequest: Codable, Equatable {
    static let schema = "staff-workspace-operational-command-v1"
    let schema: String
    let companyID: String
    let environment: String
    let replicaID: String
    let commandID: String
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let recordKind: String
    let recordID: String
    let expectedRevision: Int
    let fieldName: String
    let value: StaffWorkspaceValue

    init(companyID: String, environment: String, replicaID: String, commandID: UUID,
         selectionID: String, sourceSequence: Int, contentSHA256: String,
         candidate: StaffWorkspaceOperationalCommandCandidate, value: StaffWorkspaceValue) throws {
        guard CloudKitStaffSetupPolicy.canonicalID(companyID),
              CloudKitStaffSetupPolicy.canonicalID(replicaID),
              ["development", "production"].contains(environment),
              CloudKitStaffSetupPolicy.canonicalID(selectionID),
              CloudKitStaffSetupPolicy.canonicalID(candidate.recordID),
              (1...2_147_483_647).contains(sourceSequence),
              (1..<2_147_483_647).contains(candidate.revision),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              StaffWorkspaceOperationalCommandPolicy.isOperationsField(kind: candidate.recordKind,
                                                                       field: candidate.fieldName),
              !candidate.fieldName.hasSuffix("JSON") else {
            throw StaffReplicaDeliveryError.invalid
        }
        schema = Self.schema
        self.companyID = companyID
        self.environment = environment
        self.replicaID = replicaID
        self.commandID = commandID.uuidString.lowercased()
        self.selectionID = selectionID
        self.sourceSequence = sourceSequence
        self.contentSHA256 = contentSHA256
        recordKind = candidate.recordKind
        recordID = candidate.recordID
        expectedRevision = candidate.revision
        fieldName = candidate.fieldName
        self.value = value
    }
}

struct StaffWorkspaceOperationalCommandReceipt: Codable, Equatable {
    let schema: String
    let commandID: String
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let recordKind: String
    let recordID: String
    let expectedRevision: Int
    let fieldName: String
    let value: StaffWorkspaceValue
    let actorEmail: String
    let createdAt: String
    let state: String
    let operationalWorkspaceReady: Bool

    func validate(against request: StaffWorkspaceOperationalCommandRequest) throws {
        guard schema == StaffWorkspaceOperationalCommandRequest.schema,
              state == "recorded",
              !operationalWorkspaceReady,
              commandID == request.commandID,
              selectionID == request.selectionID,
              sourceSequence == request.sourceSequence,
              contentSHA256 == request.contentSHA256,
              recordKind == request.recordKind,
              recordID == request.recordID,
              expectedRevision == request.expectedRevision,
              fieldName == request.fieldName,
              value == request.value,
              !actorEmail.isEmpty, actorEmail.utf8.count <= 320,
              !createdAt.isEmpty, createdAt.utf8.count <= 64 else {
            throw StaffReplicaDeliveryError.invalid
        }
    }
}

struct StaffWorkspaceOperationalCommandJournal: Codable, Equatable {
    static let schema = "staff-workspace-operational-command-v1"
    let schema: String
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let request: StaffWorkspaceOperationalCommandRequest
    let state: String
    let receipt: StaffWorkspaceOperationalCommandReceipt?
    let operationalWorkspaceReady: Bool

    init(scope: CloudKitStaffSetupScope, planID: UUID, request: StaffWorkspaceOperationalCommandRequest,
         receipt: StaffWorkspaceOperationalCommandReceipt? = nil) throws {
        guard request.schema == Self.schema,
              request.environment == scope.environment,
              request.companyID == scope.company.uuidString.lowercased() else {
            throw StaffReplicaDeliveryError.invalid
        }
        if let receipt {
            try receipt.validate(against: request)
        }
        schema = Self.schema
        self.scope = scope
        self.planID = planID
        self.request = request
        state = receipt == nil ? "pending" : "recorded"
        self.receipt = receipt
        operationalWorkspaceReady = false
    }

    func validate(scope: CloudKitStaffSetupScope, plan: UUID) throws {
        guard schema == Self.schema, self.scope == scope, planID == plan,
              !operationalWorkspaceReady,
              (state == "pending" && receipt == nil) || (state == "recorded" && receipt != nil) else {
            throw StaffReplicaDeliveryError.storage
        }
        if let receipt {
            try receipt.validate(against: request)
        }
    }
}

/// Parity with Backend/staff_workspace_field_policy.py OPERATIONS allowlist.
enum StaffWorkspaceOperationalCommandPolicy {
    static let operations: [String: Set<String>] = [
        "location": ["accessNotes"],
        "equipment": ["notes"],
        "job": [
            "afterPhotoCount", "beforePhotoCount", "diagnosticsCaptured", "documentationChecklist",
            "documentationCompletedAt", "documentationStartedAt", "drainLineCondition", "equipmentNotes",
            "equipmentVerifiedChecklist", "filterCondition", "filterSize", "findingsSummary", "followUpAction",
            "indoorCoilCondition", "maintenanceChecklistComplete", "notes", "outdoorCoilCondition",
            "paymentCollectedChecklist", "quoteReviewedWithCustomer", "recommendedWorkSummary",
            "safetyChecklistComplete", "serviceReportSummary", "startupChecklistComplete",
            "thermostatOperation", "visitDispositionNotes", "workCompletedChecklist",
        ],
        "request": ["qualificationNotes"],
        "activity": ["detail"],
        "alert": ["detail", "resolutionNote"],
        "communication": ["consentSnapshotJSON"],
        "purchaseOrder": ["notes"],
        "movement": ["notes"],
        "vehicle": ["notes"],
        "vehicleEvent": ["detail"],
    ]

    static func isOperationsField(kind: String, field: String) -> Bool {
        guard let allowed = operations[kind], allowed.contains(field), !field.hasSuffix("JSON") else {
            return false
        }
        return true
    }
}

enum StaffWorkspaceOperationalCommandStore {
    static func key(_ scope: CloudKitStaffSetupScope, _ plan: UUID, commandID: String) -> String {
        "full-staff-content-command-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
            + "\n" + commandID.lowercased()
    }

    static func pendingIndexKey(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-command-pending-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    /// Discover commandable operations-policy scalars from an accepted read-only view.
    /// Only `fields` partition members; unavailable/financial/structured are excluded.
    static func candidates(from view: StaffWorkspaceOperationalView) throws -> [StaffWorkspaceOperationalCommandCandidate] {
        var result: [StaffWorkspaceOperationalCommandCandidate] = []
        var seen = Set<String>()
        for record in view.records {
            guard case let .operational(partition) = record.body else { continue }
            guard let allowed = StaffWorkspaceOperationalCommandPolicy.operations[record.kind] else { continue }
            for name in allowed.sorted() where !name.hasSuffix("JSON") {
                guard partition.unavailableFields[name] == nil,
                      partition.structuredFields[name] == nil,
                      let value = partition.fields[name] else { continue }
                let token = record.kind + ":" + record.id + ":" + name
                guard seen.insert(token).inserted else { throw StaffReplicaDeliveryError.invalid }
                result.append(.init(recordKind: record.kind, recordID: record.id, revision: record.revision,
                                    fieldName: name, currentValue: value))
            }
        }
        return result
    }

    static func load(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                     commandID: String) throws -> StaffWorkspaceOperationalCommandJournal? {
        do {
            guard let bytes = try store.read(key(scope, plan, commandID: commandID)) else { return nil }
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            let journal = try StaffWorkspacePublicationContract.decode(
                StaffWorkspaceOperationalCommandJournal.self, from: bytes, maximum: 8192)
            try journal.validate(scope: scope, plan: plan)
            guard journal.request.commandID == commandID.lowercased() ||
                    journal.request.commandID == commandID else {
                throw StaffReplicaDeliveryError.storage
            }
            return journal
        } catch let error as StaffReplicaDeliveryError {
            throw error
        } catch {
            throw StaffReplicaDeliveryError.storage
        }
    }

    static func listPending(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws
    -> [StaffWorkspaceOperationalCommandJournal] {
        guard let bytes = try store.read(pendingIndexKey(scope, plan)) else { return [] }
        guard bytes.count <= 1024 * 1024 else { throw StaffReplicaDeliveryError.storage }
        // The index is the write-ahead record: it retains each complete original
        // request even if the subsequent per-command write loses its reply.
        let originals: [StaffWorkspaceOperationalCommandJournal]
        if let current = try? StaffWorkspacePublicationContract.decode([StaffWorkspaceOperationalCommandJournal].self, from: bytes, maximum: 1024 * 1024) {
            originals = current
        } else {
            let ids = try StaffWorkspacePublicationContract.decode([String].self, from: bytes, maximum: 8192)
            originals = try ids.map {
                guard let original = try load(store: store, scope: scope, plan: plan, commandID: $0) else { throw StaffReplicaDeliveryError.storage }
                return original
            }
        }
        guard originals.count <= 128, Set(originals.map(\.request.commandID)).count == originals.count else { throw StaffReplicaDeliveryError.storage }
        var result: [StaffWorkspaceOperationalCommandJournal] = []
        for original in originals {
            try original.validate(scope: scope, plan: plan)
            let journal = try load(store: store, scope: scope, plan: plan, commandID: original.request.commandID) ?? original
            guard journal.request == original.request else { throw StaffReplicaDeliveryError.storage }
            if journal.state == "pending" { result.append(journal) }
        }
        return result.sorted { $0.request.commandID < $1.request.commandID }
    }

    @discardableResult
    static func enqueue(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                        request: StaffWorkspaceOperationalCommandRequest,
                        check: () throws -> Void = {}) throws -> StaffWorkspaceOperationalCommandJournal {
        try check()
        let next = try StaffWorkspaceOperationalCommandJournal(scope: scope, planID: plan, request: request)
        if let existing = try load(store: store, scope: scope, plan: plan, commandID: request.commandID) {
            if existing.request == request {
                try existing.validate(scope: scope, plan: plan)
                if existing.state == "recorded" { return existing }
                // Identical pending originals still repair an interrupted index.
            } else {
                throw StaffReplicaDeliveryError.changed
            }
        }
        try check()
        let encoded = try StaffWorkspacePublicationContract.encode(next)
        guard encoded.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
        var pending = try listPending(store: store, scope: scope, plan: plan)
        if let original = pending.first(where: { $0.request.commandID == request.commandID }) {
            guard original.request == request else { throw StaffReplicaDeliveryError.changed }
        } else {
            pending.append(next)
        }
        guard pending.count <= 128 else { throw StaffReplicaDeliveryError.storage }
        let index = try StaffWorkspacePublicationContract.encode(pending.sorted { $0.request.commandID < $1.request.commandID })
        guard index.count <= 1024 * 1024 else { throw StaffReplicaDeliveryError.storage }
        try check()
        try store.write(pendingIndexKey(scope, plan), index)
        try check()
        try store.write(key(scope, plan, commandID: request.commandID), encoded)
        try check()
        guard let confirmed = try load(store: store, scope: scope, plan: plan, commandID: request.commandID),
              confirmed == next else {
            throw StaffReplicaDeliveryError.storage
        }
        return confirmed
    }

    @discardableResult
    static func attachReceipt(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                              request: StaffWorkspaceOperationalCommandRequest,
                              receipt: StaffWorkspaceOperationalCommandReceipt,
                              check: () throws -> Void = {}) throws -> StaffWorkspaceOperationalCommandJournal {
        try check()
        try receipt.validate(against: request)
        let next = try StaffWorkspaceOperationalCommandJournal(scope: scope, planID: plan,
                                                               request: request, receipt: receipt)
        guard let existing = try load(store: store, scope: scope, plan: plan, commandID: request.commandID),
              existing.request == request else { throw StaffReplicaDeliveryError.changed }
        if existing.state == "recorded" {
            guard existing == next else { throw StaffReplicaDeliveryError.changed }
            try existing.validate(scope: scope, plan: plan)
            return existing
        }
        try check()
        let encoded = try StaffWorkspacePublicationContract.encode(next)
        guard encoded.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
        try store.write(key(scope, plan, commandID: request.commandID), encoded)
        // Drop from pending index once recorded.
        let remaining = try listPending(store: store, scope: scope, plan: plan)
            .filter { $0.request.commandID != request.commandID }
        let index = try StaffWorkspacePublicationContract.encode(remaining)
        guard index.count <= 1024 * 1024 else { throw StaffReplicaDeliveryError.storage }
        try store.write(pendingIndexKey(scope, plan), index)
        try check()
        guard let confirmed = try load(store: store, scope: scope, plan: plan, commandID: request.commandID),
              confirmed == next, confirmed.state == "recorded",
              confirmed.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.storage
        }
        return confirmed
    }
}
