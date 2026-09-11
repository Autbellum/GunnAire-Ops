import Foundation

/// Fail-closed local operational-workspace ready flip after independent-account
/// CloudKit convergence.
///
/// Journals `staff-workspace-operational-ready-v1` with
/// `operationalWorkspaceReady = true` — the first journal allowed to authorize
/// the flip. Prior mount / acceptance / import / store / convergence journals
/// remain historical proofs with ready false. Never rewrites mount bytes, never
/// calls owner `ModelCodec.make`, and never invents restricted-field defaults.
struct StaffWorkspaceOperationalReadyJournal: Codable, Equatable {
    static let schema = "staff-workspace-operational-ready-v1"
    let schema: String
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let sealedSHA256: String
    let ownerAccountHash: String
    let participantAccountHash: String
    let zoneName: String
    let shareRevision: Int
    let state: String
    let operationalWorkspaceReady: Bool

    init(scope: CloudKitStaffSetupScope, planID: UUID, selectionID: String,
         sourceSequence: Int, contentSHA256: String, sealedSHA256: String,
         ownerAccountHash: String, participantAccountHash: String,
         zoneName: String, shareRevision: Int) throws {
        guard CloudKitStaffSetupPolicy.canonicalID(selectionID),
              (1...2_147_483_647).contains(sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(sealedSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(ownerAccountHash),
              JobBillingAssignmentSnapshot.validConnectionRevision(participantAccountHash),
              ownerAccountHash != participantAccountHash,
              !zoneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              zoneName.count <= 255,
              (1...2_147_483_647).contains(shareRevision) else {
            throw StaffReplicaDeliveryError.invalid
        }
        schema = Self.schema
        self.scope = scope
        self.planID = planID
        self.selectionID = selectionID
        self.sourceSequence = sourceSequence
        self.contentSHA256 = contentSHA256
        self.sealedSHA256 = sealedSHA256
        self.ownerAccountHash = ownerAccountHash
        self.participantAccountHash = participantAccountHash
        self.zoneName = zoneName
        self.shareRevision = shareRevision
        state = "ready"
        operationalWorkspaceReady = true
    }

    func validate(scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
                  convergence: StaffWorkspaceOperationalConvergenceJournal,
                  storeJournal: StaffWorkspaceOperationalStoreJournal,
                  mount: StaffWorkspaceOperationalMount,
                  acceptance: StaffWorkspaceOperationalAcceptance,
                  importJournal: StaffWorkspaceOperationalImportJournal) throws {
        guard schema == Self.schema, state == "ready", operationalWorkspaceReady,
              self.scope == scope, planID == plan.id,
              selectionID == convergence.selectionID,
              sourceSequence == convergence.sourceSequence,
              contentSHA256 == convergence.contentSHA256,
              sealedSHA256 == convergence.sealedSHA256,
              ownerAccountHash == convergence.ownerAccountHash,
              participantAccountHash == convergence.participantAccountHash,
              zoneName == convergence.zoneName,
              shareRevision == convergence.shareRevision,
              convergence.state == "converged",
              convergence.operationalWorkspaceReady == false,
              selectionID == storeJournal.selectionID,
              sourceSequence == storeJournal.sourceSequence,
              contentSHA256 == storeJournal.contentSHA256,
              storeJournal.state == "activated",
              storeJournal.operationalWorkspaceReady == false,
              selectionID == mount.selectionID,
              sourceSequence == mount.sourceSequence,
              contentSHA256 == mount.contentSHA256,
              sealedSHA256 == mount.sealedSHA256,
              selectionID == acceptance.selectionID,
              sourceSequence == acceptance.sourceSequence,
              contentSHA256 == acceptance.contentSHA256,
              selectionID == importJournal.selectionID,
              sourceSequence == importJournal.sourceSequence,
              contentSHA256 == importJournal.contentSHA256,
              importJournal.operationalWorkspaceReady == false,
              ownerAccountHash == plan.ownerAccountHash,
              participantAccountHash == plan.participantAccountHash,
              zoneName == plan.zoneName,
              shareRevision == plan.revision else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}

/// Durable journal helpers for the local operational-workspace ready flip.
enum StaffWorkspaceOperationalReadyStore {
    static func key(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-ready-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    static func load(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws
    -> StaffWorkspaceOperationalReadyJournal? {
        do {
            guard let bytes = try store.read(key(scope, plan)) else { return nil }
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            let journal = try StaffWorkspacePublicationContract.decode(
                StaffWorkspaceOperationalReadyJournal.self, from: bytes, maximum: 8192)
            guard journal.schema == StaffWorkspaceOperationalReadyJournal.schema,
                  journal.state == "ready",
                  journal.operationalWorkspaceReady == true,
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

    /// Fail-closed ready flip after durable convergence + activated store.
    /// Requires mount (+ acceptance + import) digests to match the converged head.
    /// Idempotent for the same head; never rewrites mount payload bytes.
    static func markReady(plan: CloudKitStaffSharePlan,
                          store: SharedTimeLocalStore,
                          scope: CloudKitStaffSetupScope,
                          planID: UUID,
                          check: () throws -> Void = {}) throws
    -> StaffWorkspaceOperationalReadyJournal {
        try check()
        guard plan.id == planID,
              JobBillingAssignmentSnapshot.validConnectionRevision(plan.ownerAccountHash),
              JobBillingAssignmentSnapshot.validConnectionRevision(plan.participantAccountHash),
              plan.ownerAccountHash != plan.participantAccountHash else {
            throw StaffReplicaDeliveryError.access
        }
        guard let convergence = try StaffWorkspaceOperationalConvergenceStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard convergence.state == "converged",
              convergence.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.storage
        }
        guard let storeJournal = try StaffWorkspaceOperationalStoreActivator.loadJournal(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let (mount, payload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let acceptance = try StaffWorkspaceOperationalAcceptanceStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let importJournal = try StaffWorkspaceOperationalImportStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        try storeJournal.validate(scope: scope, plan: planID, importJournal: importJournal, mount: mount)
        try acceptance.validate(scope: scope, plan: planID, mount: mount)
        try importJournal.validate(scope: scope, plan: planID, acceptance: acceptance, mount: mount)

        guard storeJournal.selectionID == convergence.selectionID,
              storeJournal.contentSHA256 == convergence.contentSHA256,
              storeJournal.sourceSequence == convergence.sourceSequence,
              mount.selectionID == convergence.selectionID,
              mount.contentSHA256 == convergence.contentSHA256,
              mount.sourceSequence == convergence.sourceSequence,
              mount.sealedSHA256 == convergence.sealedSHA256,
              acceptance.selectionID == convergence.selectionID,
              acceptance.contentSHA256 == convergence.contentSHA256,
              acceptance.sourceSequence == convergence.sourceSequence,
              importJournal.selectionID == convergence.selectionID,
              importJournal.contentSHA256 == convergence.contentSHA256,
              importJournal.sourceSequence == convergence.sourceSequence,
              convergence.ownerAccountHash == plan.ownerAccountHash,
              convergence.participantAccountHash == plan.participantAccountHash,
              convergence.zoneName == plan.zoneName,
              convergence.shareRevision == plan.revision else {
            throw StaffReplicaDeliveryError.changed
        }

        let next = try StaffWorkspaceOperationalReadyJournal(
            scope: scope, planID: planID, selectionID: convergence.selectionID,
            sourceSequence: convergence.sourceSequence, contentSHA256: convergence.contentSHA256,
            sealedSHA256: convergence.sealedSHA256, ownerAccountHash: plan.ownerAccountHash,
            participantAccountHash: plan.participantAccountHash, zoneName: plan.zoneName,
            shareRevision: plan.revision)
        try next.validate(scope: scope, plan: plan, convergence: convergence,
                          storeJournal: storeJournal, mount: mount,
                          acceptance: acceptance, importJournal: importJournal)

        let previous = try load(store: store, scope: scope, plan: planID)
        if let existing = previous {
            if existing.selectionID == next.selectionID,
               existing.contentSHA256 == next.contentSHA256,
               existing.sealedSHA256 == next.sealedSHA256,
               existing.sourceSequence == next.sourceSequence,
               existing.ownerAccountHash == next.ownerAccountHash,
               existing.participantAccountHash == next.participantAccountHash,
               existing.zoneName == next.zoneName,
               existing.shareRevision == next.shareRevision {
                try existing.validate(scope: scope, plan: plan, convergence: convergence,
                                      storeJournal: storeJournal, mount: mount,
                                      acceptance: acceptance, importJournal: importJournal)
                guard existing.operationalWorkspaceReady == true,
                      existing.state == "ready" else {
                    throw StaffReplicaDeliveryError.storage
                }
                return existing
            }
            if existing.sourceSequence > next.sourceSequence {
                throw StaffReplicaDeliveryError.superseded
            }
            guard existing.sourceSequence < next.sourceSequence else { throw StaffReplicaDeliveryError.changed }
        }

        try check()
        try StaffWorkspaceOperationalJournalAdvance.commit(next, replacing: previous,
            key: key(scope, planID), store: store, check: check)
        try check()

        guard let (_, confirmedPayload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: planID),
              confirmedPayload == payload else {
            throw StaffReplicaDeliveryError.changed
        }
        // Prior journals remain historical proofs with ready false.
        guard let confirmedConvergence = try StaffWorkspaceOperationalConvergenceStore.load(
            store: store, scope: scope, plan: planID),
              confirmedConvergence.operationalWorkspaceReady == false,
              let confirmedStore = try StaffWorkspaceOperationalStoreActivator.loadJournal(
                store: store, scope: scope, plan: planID),
              confirmedStore.operationalWorkspaceReady == false,
              let confirmedImport = try StaffWorkspaceOperationalImportStore.load(
                store: store, scope: scope, plan: planID),
              confirmedImport.operationalWorkspaceReady == false,
              let confirmed = try load(store: store, scope: scope, plan: planID),
              confirmed == next,
              confirmed.operationalWorkspaceReady == true,
              confirmed.state == "ready" else {
            throw StaffReplicaDeliveryError.storage
        }
        try confirmed.validate(scope: scope, plan: plan, convergence: confirmedConvergence,
                               storeJournal: confirmedStore, mount: mount,
                               acceptance: acceptance, importJournal: confirmedImport)
        return confirmed
    }
}
