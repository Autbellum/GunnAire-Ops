import Foundation
import CloudKit

/// Independent-account CloudKit convergence proof after store-v1 activation.
///
/// Proves the activated staff projection matches a fresh participant CloudKit head
/// (shared-zone owner account hash). Journals
/// `staff-workspace-operational-convergence-v1` without flipping
/// `operationalWorkspaceReady`, rewriting mount bytes, or calling owner
/// `ModelCodec.make`.
struct StaffWorkspaceOperationalConvergenceJournal: Codable, Equatable {
    static let schema = "staff-workspace-operational-convergence-v1"
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
        state = "converged"
        operationalWorkspaceReady = false
    }

    func validate(scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
                  storeJournal: StaffWorkspaceOperationalStoreJournal,
                  mount: StaffWorkspaceOperationalMount,
                  head: StaffWorkspaceCloudSealManifest) throws {
        guard schema == Self.schema, state == "converged", !operationalWorkspaceReady,
              self.scope == scope, planID == plan.id,
              selectionID == storeJournal.selectionID,
              sourceSequence == storeJournal.sourceSequence,
              contentSHA256 == storeJournal.contentSHA256,
              selectionID == mount.selectionID,
              sourceSequence == mount.sourceSequence,
              contentSHA256 == mount.contentSHA256,
              sealedSHA256 == mount.sealedSHA256,
              selectionID == head.selectionID,
              sourceSequence == head.sourceSequence,
              contentSHA256 == head.contentSHA256,
              sealedSHA256 == head.sealedSHA256,
              ownerAccountHash == plan.ownerAccountHash,
              participantAccountHash == plan.participantAccountHash,
              zoneName == plan.zoneName,
              shareRevision == plan.revision,
              shareRevision == head.shareRevision else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}

/// Durable journal helpers for independent-account CloudKit convergence proof.
enum StaffWorkspaceOperationalConvergenceStore {
    static func key(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-convergence-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    static func load(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws
    -> StaffWorkspaceOperationalConvergenceJournal? {
        do {
            guard let bytes = try store.read(key(scope, plan)) else { return nil }
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            let journal = try StaffWorkspacePublicationContract.decode(
                StaffWorkspaceOperationalConvergenceJournal.self, from: bytes, maximum: 8192)
            guard journal.schema == StaffWorkspaceOperationalConvergenceJournal.schema,
                  journal.state == "converged",
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

    /// Fail-closed zone authority: shared-zone owner must not be the current user,
    /// and zone-owner account hash must equal the plan owner hash.
    static func requireParticipantZone(_ io: StaffReplicaCloudIO, plan: CloudKitStaffSharePlan) throws {
        guard io.zone.zoneName == plan.zoneName,
              io.zone.ownerName != CKCurrentUserDefaultName,
              CloudKitStaffSharePlan.accountHash(
                recordName: io.zone.ownerName, environment: plan.environment) == plan.ownerAccountHash else {
            throw StaffReplicaDeliveryError.access
        }
    }

    /// Journal convergence of an activated store against a fresh participant CK head.
    /// Requires activated store journal + mount (+ import) matching head digests.
    /// Idempotent for the same head; never flips `operationalWorkspaceReady`.
    static func prove(head: StaffWorkspaceCloudSealManifest,
                      plan: CloudKitStaffSharePlan,
                      participantAccountHash: String,
                      zoneName: String,
                      store: SharedTimeLocalStore,
                      scope: CloudKitStaffSetupScope,
                      planID: UUID,
                      check: () throws -> Void = {}) throws
    -> StaffWorkspaceOperationalConvergenceJournal {
        try check()
        guard plan.id == planID,
              participantAccountHash == plan.participantAccountHash,
              zoneName == plan.zoneName,
              head.shareRevision == plan.revision,
              JobBillingAssignmentSnapshot.validConnectionRevision(plan.ownerAccountHash),
              JobBillingAssignmentSnapshot.validConnectionRevision(participantAccountHash),
              plan.ownerAccountHash != participantAccountHash else {
            throw StaffReplicaDeliveryError.access
        }
        guard let storeJournal = try StaffWorkspaceOperationalStoreActivator.loadJournal(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let (mount, payload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let importJournal = try StaffWorkspaceOperationalImportStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        try storeJournal.validate(scope: scope, plan: planID, importJournal: importJournal, mount: mount)

        guard storeJournal.selectionID == head.selectionID,
              storeJournal.contentSHA256 == head.contentSHA256,
              storeJournal.sourceSequence == head.sourceSequence,
              mount.selectionID == head.selectionID,
              mount.contentSHA256 == head.contentSHA256,
              mount.sourceSequence == head.sourceSequence,
              mount.sealedSHA256 == head.sealedSHA256 else {
            throw StaffReplicaDeliveryError.changed
        }

        let next = try StaffWorkspaceOperationalConvergenceJournal(
            scope: scope, planID: planID, selectionID: head.selectionID,
            sourceSequence: head.sourceSequence, contentSHA256: head.contentSHA256,
            sealedSHA256: head.sealedSHA256, ownerAccountHash: plan.ownerAccountHash,
            participantAccountHash: participantAccountHash, zoneName: zoneName,
            shareRevision: plan.revision)
        try next.validate(scope: scope, plan: plan, storeJournal: storeJournal, mount: mount, head: head)

        if let existing = try load(store: store, scope: scope, plan: planID) {
            if existing.selectionID == next.selectionID,
               existing.contentSHA256 == next.contentSHA256,
               existing.sealedSHA256 == next.sealedSHA256,
               existing.sourceSequence == next.sourceSequence,
               existing.ownerAccountHash == next.ownerAccountHash,
               existing.participantAccountHash == next.participantAccountHash,
               existing.zoneName == next.zoneName,
               existing.shareRevision == next.shareRevision {
                try existing.validate(scope: scope, plan: plan, storeJournal: storeJournal,
                                      mount: mount, head: head)
                guard existing.operationalWorkspaceReady == false else {
                    throw StaffReplicaDeliveryError.storage
                }
                return existing
            }
            if existing.sourceSequence > next.sourceSequence {
                throw StaffReplicaDeliveryError.superseded
            }
            throw StaffReplicaDeliveryError.changed
        }

        try check()
        let encoded = try StaffWorkspacePublicationContract.encode(next)
        guard encoded.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
        try store.write(key(scope, planID), encoded)
        try check()

        guard let (_, confirmedPayload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: planID),
              confirmedPayload == payload else {
            throw StaffReplicaDeliveryError.changed
        }
        guard let confirmed = try load(store: store, scope: scope, plan: planID),
              confirmed == next,
              confirmed.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.storage
        }
        try confirmed.validate(scope: scope, plan: plan, storeJournal: storeJournal, mount: mount, head: head)
        return confirmed
    }
}
