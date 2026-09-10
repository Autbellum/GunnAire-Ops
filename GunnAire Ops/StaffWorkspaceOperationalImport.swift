import Foundation

/// Staff-scoped ModelContext import adapters after semantic acceptance.
///
/// Builds a fail-closed import plan from `StaffWorkspaceOperationalView` without
/// inventing SwiftData defaults for restricted/unavailable fields, without
/// rewriting mounted content bytes, and without flipping `operationalWorkspaceReady`.
/// Dedicated staff projection store activation is a separate store-v1 step.
/// Writes are OPERATIONS-policy command intents only (wire to `submitOperationalCommand`).
struct StaffWorkspaceOperationalImportJournal: Codable, Equatable {
    static let schema = "staff-workspace-operational-import-v1"
    let schema: String
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let recordCount: Int
    let state: String
    let operationalWorkspaceReady: Bool

    init(scope: CloudKitStaffSetupScope, planID: UUID, selectionID: String,
         sourceSequence: Int, contentSHA256: String, recordCount: Int) throws {
        guard CloudKitStaffSetupPolicy.canonicalID(selectionID),
              (1...2_147_483_647).contains(sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              (0...20_000).contains(recordCount) else {
            throw StaffReplicaDeliveryError.invalid
        }
        schema = Self.schema
        self.scope = scope
        self.planID = planID
        self.selectionID = selectionID
        self.sourceSequence = sourceSequence
        self.contentSHA256 = contentSHA256
        self.recordCount = recordCount
        state = "imported"
        operationalWorkspaceReady = false
    }

    func validate(scope: CloudKitStaffSetupScope, plan: UUID,
                  acceptance: StaffWorkspaceOperationalAcceptance,
                  mount: StaffWorkspaceOperationalMount) throws {
        guard schema == Self.schema, state == "imported", !operationalWorkspaceReady,
              self.scope == scope, planID == plan,
              selectionID == acceptance.selectionID,
              sourceSequence == acceptance.sourceSequence,
              contentSHA256 == acceptance.contentSHA256,
              recordCount == acceptance.recordCount,
              selectionID == mount.selectionID,
              sourceSequence == mount.sourceSequence,
              contentSHA256 == mount.contentSHA256 else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}

/// Staff-scoped import record preserving explicit unavailable partitions.
/// Never a reconstructed owner `@Model` via `ModelCodec.make`.
struct StaffWorkspaceOperationalImportRecord: Equatable {
    let kind: String
    let id: String
    let revision: Int
    let unavailableLinks: [String]
    let body: StaffWorkspaceOperationalView.Body
}

/// Import plan rebuilt from an accepted operational view. Holds only mapped
/// available fields plus explicit unavailable / structured partitions.
struct StaffWorkspaceOperationalImportPlan: Equatable {
    let schema: String
    let selectionID: String
    let contentSHA256: String
    let sourceSequence: Int
    let companyID: String
    let environment: String
    let replicaID: String
    let memberRole: String
    let records: [StaffWorkspaceOperationalImportRecord]
    let operationalWorkspaceReady: Bool

    var recordCount: Int { records.count }

    func record(kind: String, id: String) -> StaffWorkspaceOperationalImportRecord? {
        records.first { $0.kind == kind && $0.id == id }
    }
}

/// Staff import bag for display reads. When a dedicated staff projection
/// `ModelContainer` is attached (`staff-workspace-operational-store-v1`), reads
/// come from live projection models; otherwise reads come from the import plan.
/// A ready-v1 journal (`operationalWorkspaceReady == true`) authorizes the
/// activated store as the operational workspace; presence alone never calls
/// owner `ModelCodec.make` or invents restricted-field defaults.
struct StaffWorkspaceOperationalImportContainer {
    let plan: StaffWorkspaceOperationalImportPlan
    /// Live dedicated staff projection store from store-v1 activation, if any.
    let activatedStore: StaffWorkspaceOperationalActivatedStore?
    /// Durable ready-v1 journal when the operational workspace flip is authorized.
    let readyJournal: StaffWorkspaceOperationalReadyJournal?
    /// True when a live dedicated staff projection ModelContainer is attached.
    var modelContainerPresent: Bool { activatedStore != nil }
    /// True when ready-v1 authorizes the activated store for staff use.
    var operationalWorkspaceReady: Bool {
        readyJournal?.operationalWorkspaceReady == true && readyJournal?.state == "ready"
    }

    init(plan: StaffWorkspaceOperationalImportPlan,
         activatedStore: StaffWorkspaceOperationalActivatedStore? = nil,
         readyJournal: StaffWorkspaceOperationalReadyJournal? = nil) {
        self.plan = plan
        self.activatedStore = activatedStore
        self.readyJournal = readyJournal
    }
}

enum StaffWorkspaceOperationalImportReadAdapter {
    /// Fetch/display imported staff records from the plan, or from live projection
    /// models when a dedicated store is activated. Never invents defaults for unavailable.
    static func fetch(container: StaffWorkspaceOperationalImportContainer,
                      kind: String? = nil, id: String? = nil) throws -> [StaffWorkspaceOperationalImportRecord] {
        try validatePlan(container.plan)
        // Ready-aware path: ready-v1 journal alone authorizes activated-store reads
        // after the local operational-workspace flip.
        if let ready = container.readyJournal {
            guard ready.schema == StaffWorkspaceOperationalReadyJournal.schema,
                  ready.state == "ready",
                  ready.operationalWorkspaceReady == true,
                  let activated = container.activatedStore,
                  activated.journal.selectionID == ready.selectionID,
                  activated.journal.contentSHA256 == ready.contentSHA256,
                  activated.journal.sourceSequence == ready.sourceSequence,
                  activated.plan.contentSHA256 == container.plan.contentSHA256,
                  activated.plan.sourceSequence == container.plan.sourceSequence,
                  activated.plan.selectionID == container.plan.selectionID,
                  activated.plan.recordCount == container.plan.recordCount,
                  ready.contentSHA256 == container.plan.contentSHA256,
                  ready.sourceSequence == container.plan.sourceSequence,
                  ready.selectionID == container.plan.selectionID else {
                throw StaffReplicaDeliveryError.changed
            }
            return try activated.fetch(kind: kind, id: id)
        }
        // Pre-ready path: activated store journals remain ready=false historical proofs.
        if let activated = container.activatedStore {
            guard activated.journal.operationalWorkspaceReady == false,
                  activated.plan.contentSHA256 == container.plan.contentSHA256,
                  activated.plan.sourceSequence == container.plan.sourceSequence,
                  activated.plan.selectionID == container.plan.selectionID,
                  activated.plan.recordCount == container.plan.recordCount else {
                throw StaffReplicaDeliveryError.changed
            }
            return try activated.fetch(kind: kind, id: id)
        }
        var result = container.plan.records
        if let kind {
            result = result.filter { $0.kind == kind }
        }
        if let id {
            guard CloudKitStaffSetupPolicy.canonicalID(id) else { throw StaffReplicaDeliveryError.invalid }
            result = result.filter { $0.id == id }
        }
        return result
    }

    static func displayFields(for record: StaffWorkspaceOperationalImportRecord) throws -> [String: StaffWorkspaceValue] {
        switch record.body {
        case let .billing(document):
            // Map only available billing fields; unavailable stay explicit outside.
            return document.fields
        case let .operational(partition):
            return partition.fields
        }
    }

    static func unavailableFields(for record: StaffWorkspaceOperationalImportRecord)
    -> [String: StaffWorkspaceBillingProjection.Unavailable] {
        switch record.body {
        case let .billing(document):
            return document.unavailableFields
        case let .operational(partition):
            return partition.unavailableFields
        }
    }

    private static func validatePlan(_ plan: StaffWorkspaceOperationalImportPlan) throws {
        guard plan.schema == StaffWorkspaceOperationalImportJournal.schema,
              !plan.operationalWorkspaceReady,
              CloudKitStaffSetupPolicy.canonicalID(plan.selectionID),
              JobBillingAssignmentSnapshot.validConnectionRevision(plan.contentSHA256),
              (1...2_147_483_647).contains(plan.sourceSequence),
              plan.records.count <= 20_000 else {
            throw StaffReplicaDeliveryError.invalid
        }
    }
}

enum StaffWorkspaceOperationalImportWriteAdapter {
    /// OPERATIONS-policy field mutation as a command intent only.
    /// Does not mutate mounted content bytes and does not activate a staff store.
    /// Callers submit via `StaffWorkspaceContentCoordinator.submitOperationalCommand`
    /// (or enqueue through `StaffWorkspaceOperationalCommandStore`).
    static func commandIntent(plan: StaffWorkspaceOperationalImportPlan,
                              recordKind: String, recordID: String, fieldName: String,
                              value: StaffWorkspaceValue, commandID: UUID) throws
    -> StaffWorkspaceOperationalCommandRequest {
        guard !plan.operationalWorkspaceReady else { throw StaffReplicaDeliveryError.invalid }
        guard CloudKitStaffSetupPolicy.canonicalID(recordID),
              StaffWorkspaceOperationalCommandPolicy.isOperationsField(kind: recordKind, field: fieldName) else {
            throw StaffReplicaDeliveryError.invalid
        }
        guard let record = plan.record(kind: recordKind, id: recordID) else {
            throw StaffReplicaDeliveryError.invalid
        }
        guard case let .operational(partition) = record.body else {
            throw StaffReplicaDeliveryError.invalid
        }
        // Unavailable / structured / missing available field → fail closed.
        guard partition.unavailableFields[fieldName] == nil,
              partition.structuredFields[fieldName] == nil,
              partition.fields[fieldName] != nil else {
            throw StaffReplicaDeliveryError.invalid
        }
        let candidate = StaffWorkspaceOperationalCommandCandidate(
            recordKind: recordKind, recordID: recordID, revision: record.revision,
            fieldName: fieldName, currentValue: partition.fields[fieldName]!)
        return try StaffWorkspaceOperationalCommandRequest(
            companyID: plan.companyID, environment: plan.environment, replicaID: plan.replicaID,
            commandID: commandID, selectionID: plan.selectionID, sourceSequence: plan.sourceSequence,
            contentSHA256: plan.contentSHA256, candidate: candidate, value: value)
    }
}

enum StaffWorkspaceOperationalImportStore {
    static func key(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-import-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    static func load(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws
    -> StaffWorkspaceOperationalImportJournal? {
        do {
            guard let bytes = try store.read(key(scope, plan)) else { return nil }
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            let journal = try StaffWorkspacePublicationContract.decode(
                StaffWorkspaceOperationalImportJournal.self, from: bytes, maximum: 8192)
            guard journal.schema == StaffWorkspaceOperationalImportJournal.schema,
                  journal.state == "imported",
                  journal.operationalWorkspaceReady == false,
                  journal.scope == scope, journal.planID == plan else {
                throw StaffReplicaDeliveryError.storage
            }
            return journal
        } catch let error as StaffReplicaDeliveryError {
            throw error
        } catch {
            throw StaffReplicaDeliveryError.storage
        }
    }

    /// Build a staff-scoped import plan from an accepted operational view.
    /// Billing bodies reuse the typed projection fields only; operational bodies
    /// keep fields / unavailableFields / structuredFields. Never calls owner
    /// `ModelCodec.make`.
    static func plan(from view: StaffWorkspaceOperationalView) throws -> StaffWorkspaceOperationalImportPlan {
        guard CloudKitStaffSetupPolicy.canonicalID(view.selectionID),
              JobBillingAssignmentSnapshot.validConnectionRevision(view.contentSHA256),
              (1...2_147_483_647).contains(view.sourceSequence),
              view.records.count <= 20_000,
              view.schema == "staff-workspace-content-v1" else {
            throw StaffReplicaDeliveryError.invalid
        }
        var records: [StaffWorkspaceOperationalImportRecord] = []
        var seen = Set<String>()
        for record in view.records {
            let token = record.kind + ":" + record.id
            guard seen.insert(token).inserted else { throw StaffReplicaDeliveryError.invalid }
            let body: StaffWorkspaceOperationalView.Body
            switch record.body {
            case let .billing(document):
                // Map only available fields; keep unavailable explicit — do not
                // invent nil/0/"" for restricted keys.
                try validateBillingPartition(document)
                body = .billing(document)
            case let .operational(partition):
                try validateOperationalPartition(partition)
                body = .operational(partition)
            }
            records.append(.init(kind: record.kind, id: record.id, revision: record.revision,
                                 unavailableLinks: record.unavailableLinks, body: body))
        }
        return StaffWorkspaceOperationalImportPlan(
            schema: StaffWorkspaceOperationalImportJournal.schema,
            selectionID: view.selectionID, contentSHA256: view.contentSHA256,
            sourceSequence: view.sourceSequence, companyID: view.companyID,
            environment: view.environment, replicaID: view.replicaID,
            memberRole: view.memberRole, records: records, operationalWorkspaceReady: false)
    }

    /// Require durable mount + acceptance bound to selection/content/sequence,
    /// build plan, journal import. Idempotent for the same mounted head.
    @discardableResult
    static func importAccepted(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                               selectionID: String? = nil, check: () throws -> Void = {}) throws
    -> StaffWorkspaceOperationalImportPlan {
        try check()
        guard let (mount, payload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: plan) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let acceptance = try StaffWorkspaceOperationalAcceptanceStore.load(
            store: store, scope: scope, plan: plan) else {
            throw StaffReplicaDeliveryError.pending
        }
        if let selectionID {
            guard acceptance.selectionID == selectionID, mount.selectionID == selectionID else {
                throw StaffReplicaDeliveryError.changed
            }
        }
        // Acceptance must still bind the current mount head.
        do {
            try acceptance.validate(scope: scope, plan: plan, mount: mount)
        } catch {
            // Mount advanced past acceptance → refuse as superseded.
            if acceptance.sourceSequence < mount.sourceSequence
                || acceptance.contentSHA256 != mount.contentSHA256
                || acceptance.selectionID != mount.selectionID {
                throw StaffReplicaDeliveryError.superseded
            }
            throw StaffReplicaDeliveryError.changed
        }
        guard payload.count == mount.contentBytes,
              StaffReplicaManifest.hash(payload) == mount.contentSHA256 else {
            throw StaffReplicaDeliveryError.changed
        }
        // Re-parse view from mount (fail-closed) rather than trusting a stale bag.
        let view = try StaffWorkspaceOperationalAcceptanceStore.parse(opened: payload, mount: mount)
        guard view.selectionID == acceptance.selectionID,
              view.contentSHA256 == acceptance.contentSHA256,
              view.sourceSequence == acceptance.sourceSequence,
              view.records.count == acceptance.recordCount else {
            throw StaffReplicaDeliveryError.changed
        }
        let nextPlan = try Self.plan(from: view)
        try check()
        let journal = try StaffWorkspaceOperationalImportJournal(
            scope: scope, planID: plan, selectionID: mount.selectionID,
            sourceSequence: mount.sourceSequence, contentSHA256: mount.contentSHA256,
            recordCount: nextPlan.recordCount)
        if let existing = try load(store: store, scope: scope, plan: plan) {
            if existing.selectionID == journal.selectionID,
               existing.contentSHA256 == journal.contentSHA256,
               existing.sourceSequence == journal.sourceSequence,
               existing.recordCount == journal.recordCount {
                try existing.validate(scope: scope, plan: plan, acceptance: acceptance, mount: mount)
                guard existing.operationalWorkspaceReady == false else {
                    throw StaffReplicaDeliveryError.storage
                }
                return nextPlan // Idempotent re-import of the same head.
            }
            // Prior import journal for a different head — only replace after the
            // current mount/acceptance bind succeeds (above). If the retained
            // journal is newer than the requested mount head, refuse.
            if existing.sourceSequence > journal.sourceSequence {
                throw StaffReplicaDeliveryError.superseded
            }
        }
        try check()
        let encoded = try StaffWorkspacePublicationContract.encode(journal)
        guard encoded.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
        try store.write(key(scope, plan), encoded)
        try check()
        // Mount payload bytes must be unchanged by import.
        guard let (_, confirmedPayload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: plan),
              confirmedPayload == payload else {
            throw StaffReplicaDeliveryError.changed
        }
        guard let confirmed = try load(store: store, scope: scope, plan: plan), confirmed == journal,
              confirmed.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.storage
        }
        try confirmed.validate(scope: scope, plan: plan, acceptance: acceptance, mount: mount)
        return nextPlan
    }

    /// Rebuild plan from journal + current accepted mount, or nil when no journal.
    static func loadPlan(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID,
                         check: () throws -> Void = {}) throws -> StaffWorkspaceOperationalImportPlan? {
        try check()
        guard let journal = try load(store: store, scope: scope, plan: plan) else { return nil }
        guard let (mount, payload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: plan) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let acceptance = try StaffWorkspaceOperationalAcceptanceStore.load(
            store: store, scope: scope, plan: plan) else {
            throw StaffReplicaDeliveryError.pending
        }
        if journal.sourceSequence < mount.sourceSequence
            || journal.contentSHA256 != mount.contentSHA256
            || journal.selectionID != mount.selectionID {
            throw StaffReplicaDeliveryError.superseded
        }
        try journal.validate(scope: scope, plan: plan, acceptance: acceptance, mount: mount)
        let view = try StaffWorkspaceOperationalAcceptanceStore.parse(opened: payload, mount: mount)
        let rebuilt = try Self.plan(from: view)
        guard rebuilt.recordCount == journal.recordCount,
              rebuilt.contentSHA256 == journal.contentSHA256,
              !rebuilt.operationalWorkspaceReady else {
            throw StaffReplicaDeliveryError.changed
        }
        return rebuilt
    }

    private static func validateBillingPartition(_ document: StaffWorkspaceBillingProjection.Document) throws {
        let fieldKeys = Set(document.fields.keys)
        let unavailableKeys = Set(document.unavailableFields.keys)
        guard fieldKeys.isDisjoint(with: unavailableKeys) else { throw StaffReplicaDeliveryError.invalid }
        for name in unavailableKeys {
            guard document.fields[name] == nil else { throw StaffReplicaDeliveryError.invalid }
        }
        guard document.unavailableFields.values.allSatisfy({
            $0 == .roleRestricted || $0 == .serviceOnly
        }) else { throw StaffReplicaDeliveryError.invalid }
    }

    private static func validateOperationalPartition(_ partition: StaffWorkspaceOperationalView.OperationalPartition) throws {
        let fieldKeys = Set(partition.fields.keys)
        let unavailableKeys = Set(partition.unavailableFields.keys)
        let structuredKeys = Set(partition.structuredFields.keys)
        guard fieldKeys.isDisjoint(with: unavailableKeys),
              fieldKeys.isDisjoint(with: structuredKeys),
              unavailableKeys.isDisjoint(with: structuredKeys),
              fieldKeys.allSatisfy({ !$0.hasSuffix("JSON") }),
              partition.unavailableFields.values.allSatisfy({
                  $0 == .roleRestricted || $0 == .serviceOnly
              }) else {
            throw StaffReplicaDeliveryError.invalid
        }
        for name in unavailableKeys {
            guard partition.fields[name] == nil, partition.structuredFields[name] == nil else {
                throw StaffReplicaDeliveryError.invalid
            }
        }
    }
}
