import Foundation
import SwiftData

/// Fail-closed staff projection host after the local operational-workspace ready flip.
///
/// Journals `staff-workspace-operational-host-v1` with `state = hosted` and
/// `operationalWorkspaceReady = true` once a ready journal authorizes attaching the
/// activated staff projection ModelContainer. This is a separate staff projection
/// host — it never unlocks the owner ModelContainer, never calls owner
/// `ModelCodec.make`, never invents restricted-field defaults, and never rewrites
/// mount payload bytes. Prior ready/store/convergence/import journals remain
/// historical proofs (ready-v1 stays true; intermediate journals stay false).
struct StaffWorkspaceOperationalHostJournal: Codable, Equatable {
    static let schema = "staff-workspace-operational-host-v1"
    let schema: String
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let sealedSHA256: String
    let recordCount: Int
    let state: String
    let operationalWorkspaceReady: Bool

    init(scope: CloudKitStaffSetupScope, planID: UUID, selectionID: String,
         sourceSequence: Int, contentSHA256: String, sealedSHA256: String,
         recordCount: Int) throws {
        guard CloudKitStaffSetupPolicy.canonicalID(selectionID),
              (1...2_147_483_647).contains(sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(sealedSHA256),
              (0...20_000).contains(recordCount) else {
            throw StaffReplicaDeliveryError.invalid
        }
        schema = Self.schema
        self.scope = scope
        self.planID = planID
        self.selectionID = selectionID
        self.sourceSequence = sourceSequence
        self.contentSHA256 = contentSHA256
        self.sealedSHA256 = sealedSHA256
        self.recordCount = recordCount
        state = "hosted"
        operationalWorkspaceReady = true
    }

    func validate(scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
                  ready: StaffWorkspaceOperationalReadyJournal,
                  storeJournal: StaffWorkspaceOperationalStoreJournal,
                  mount: StaffWorkspaceOperationalMount) throws {
        guard schema == Self.schema, state == "hosted", operationalWorkspaceReady,
              self.scope == scope, planID == plan.id,
              selectionID == ready.selectionID,
              sourceSequence == ready.sourceSequence,
              contentSHA256 == ready.contentSHA256,
              sealedSHA256 == ready.sealedSHA256,
              ready.state == "ready",
              ready.operationalWorkspaceReady == true,
              selectionID == storeJournal.selectionID,
              sourceSequence == storeJournal.sourceSequence,
              contentSHA256 == storeJournal.contentSHA256,
              recordCount == storeJournal.recordCount,
              storeJournal.state == "activated",
              storeJournal.operationalWorkspaceReady == false,
              selectionID == mount.selectionID,
              sourceSequence == mount.sourceSequence,
              contentSHA256 == mount.contentSHA256,
              sealedSHA256 == mount.sealedSHA256,
              plan.state == "accepted",
              plan.businessAccessEligible,
              !plan.reviewRequired,
              !plan.cloudKitRevocationRequired else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}

/// Live handle wrapping an activated staff projection store after host-v1 attach.
/// Explicitly nonisolated: module default isolation is MainActor, and XCTest
/// releases locals off the main actor — a MainActor class deinit aborts via
/// `swift_task_deinitOnExecutorImpl`.
nonisolated final class StaffWorkspaceOperationalHostedStore: @unchecked Sendable {
    let journal: StaffWorkspaceOperationalHostJournal
    let activated: StaffWorkspaceOperationalActivatedStore

    init(journal: StaffWorkspaceOperationalHostJournal,
         activated: StaffWorkspaceOperationalActivatedStore) {
        self.journal = journal
        self.activated = activated
    }

    var container: ModelContainer { activated.container }
    var plan: StaffWorkspaceOperationalImportPlan { activated.plan }

    func fetch(kind: String? = nil, id: String? = nil) throws -> [StaffWorkspaceOperationalImportRecord] {
        guard journal.schema == StaffWorkspaceOperationalHostJournal.schema,
              journal.state == "hosted",
              journal.operationalWorkspaceReady,
              activated.journal.selectionID == journal.selectionID,
              activated.journal.contentSHA256 == journal.contentSHA256,
              activated.journal.sourceSequence == journal.sourceSequence,
              activated.journal.recordCount == journal.recordCount,
              activated.journal.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.storage
        }
        return try activated.fetch(kind: kind, id: id)
    }
}

/// Durable journal helpers for the staff projection operational host.
enum StaffWorkspaceOperationalHostStore {
    static func key(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-host-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    static func loadJournal(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws
    -> StaffWorkspaceOperationalHostJournal? {
        do {
            guard let bytes = try store.read(key(scope, plan)) else { return nil }
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            let journal = try StaffWorkspacePublicationContract.decode(
                StaffWorkspaceOperationalHostJournal.self, from: bytes, maximum: 8192)
            guard journal.schema == StaffWorkspaceOperationalHostJournal.schema,
                  journal.state == "hosted",
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

    private static func requireEligiblePlan(_ plan: CloudKitStaffSharePlan, planID: UUID) throws {
        guard plan.id == planID,
              plan.state == "accepted",
              plan.businessAccessEligible,
              !plan.reviewRequired,
              !plan.cloudKitRevocationRequired else {
            throw StaffReplicaDeliveryError.changed
        }
    }

    /// Fail-closed host attach after durable ready + matching activated store.
    /// Idempotent for the same head; never rewrites mount payload bytes; never
    /// flips or rewrites prior ready=false intermediate journals.
    @MainActor
    static func open(plan: CloudKitStaffSharePlan,
                     store: SharedTimeLocalStore,
                     scope: CloudKitStaffSetupScope,
                     planID: UUID,
                     check: () throws -> Void = {}) throws
    -> StaffWorkspaceOperationalHostedStore {
        try check()
        try requireEligiblePlan(plan, planID: planID)

        guard let ready = try StaffWorkspaceOperationalReadyStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard ready.operationalWorkspaceReady == true, ready.state == "ready" else {
            throw StaffReplicaDeliveryError.storage
        }

        guard let (mount, payload) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let storeJournal = try StaffWorkspaceOperationalStoreActivator.loadJournal(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }

        guard storeJournal.selectionID == ready.selectionID,
              storeJournal.contentSHA256 == ready.contentSHA256,
              storeJournal.sourceSequence == ready.sourceSequence,
              mount.selectionID == ready.selectionID,
              mount.contentSHA256 == ready.contentSHA256,
              mount.sourceSequence == ready.sourceSequence,
              mount.sealedSHA256 == ready.sealedSHA256 else {
            throw StaffReplicaDeliveryError.changed
        }

        try check()
        guard let activated = try StaffWorkspaceOperationalStoreActivator.loadActivated(
            store: store, scope: scope, planID: planID, check: check) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard activated.journal.selectionID == ready.selectionID,
              activated.journal.contentSHA256 == ready.contentSHA256,
              activated.journal.sourceSequence == ready.sourceSequence,
              activated.journal.recordCount == storeJournal.recordCount,
              activated.plan.selectionID == ready.selectionID,
              activated.plan.contentSHA256 == ready.contentSHA256,
              activated.plan.sourceSequence == ready.sourceSequence,
              activated.journal.operationalWorkspaceReady == false,
              activated.plan.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.changed
        }

        let next = try StaffWorkspaceOperationalHostJournal(
            scope: scope, planID: planID, selectionID: ready.selectionID,
            sourceSequence: ready.sourceSequence, contentSHA256: ready.contentSHA256,
            sealedSHA256: ready.sealedSHA256, recordCount: storeJournal.recordCount)
        try next.validate(scope: scope, plan: plan, ready: ready,
                          storeJournal: storeJournal, mount: mount)

        if let existing = try loadJournal(store: store, scope: scope, plan: planID) {
            if existing.selectionID == next.selectionID,
               existing.contentSHA256 == next.contentSHA256,
               existing.sealedSHA256 == next.sealedSHA256,
               existing.sourceSequence == next.sourceSequence,
               existing.recordCount == next.recordCount {
                try existing.validate(scope: scope, plan: plan, ready: ready,
                                      storeJournal: storeJournal, mount: mount)
                guard existing.operationalWorkspaceReady == true,
                      existing.state == "hosted" else {
                    throw StaffReplicaDeliveryError.storage
                }
                return StaffWorkspaceOperationalHostedStore(journal: existing, activated: activated)
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
        // Prior journals remain historical proofs — intermediate ready=false, ready-v1 true.
        guard let confirmedReady = try StaffWorkspaceOperationalReadyStore.load(
            store: store, scope: scope, plan: planID),
              confirmedReady == ready,
              confirmedReady.operationalWorkspaceReady == true,
              confirmedReady.state == "ready",
              let confirmedStore = try StaffWorkspaceOperationalStoreActivator.loadJournal(
                store: store, scope: scope, plan: planID),
              confirmedStore.operationalWorkspaceReady == false,
              let confirmedImport = try StaffWorkspaceOperationalImportStore.load(
                store: store, scope: scope, plan: planID),
              confirmedImport.operationalWorkspaceReady == false,
              let confirmedConvergence = try StaffWorkspaceOperationalConvergenceStore.load(
                store: store, scope: scope, plan: planID),
              confirmedConvergence.operationalWorkspaceReady == false,
              let confirmed = try loadJournal(store: store, scope: scope, plan: planID),
              confirmed == next,
              confirmed.operationalWorkspaceReady == true,
              confirmed.state == "hosted" else {
            throw StaffReplicaDeliveryError.storage
        }
        try confirmed.validate(scope: scope, plan: plan, ready: confirmedReady,
                               storeJournal: confirmedStore, mount: mount)
        return StaffWorkspaceOperationalHostedStore(journal: confirmed, activated: activated)
    }

    /// Rebuild a live hosted staff projection handle from the durable host journal
    /// + matching ready/activated digests, or nil when no host journal exists.
    @MainActor
    static func load(plan: CloudKitStaffSharePlan,
                     store: SharedTimeLocalStore,
                     scope: CloudKitStaffSetupScope,
                     planID: UUID,
                     check: () throws -> Void = {}) throws
    -> StaffWorkspaceOperationalHostedStore? {
        try check()
        try requireEligiblePlan(plan, planID: planID)
        guard let journal = try loadJournal(store: store, scope: scope, plan: planID) else { return nil }
        guard let ready = try StaffWorkspaceOperationalReadyStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let (mount, _) = try StaffWorkspaceOperationalMountStore.load(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard let storeJournal = try StaffWorkspaceOperationalStoreActivator.loadJournal(
            store: store, scope: scope, plan: planID) else {
            throw StaffReplicaDeliveryError.pending
        }
        if journal.sourceSequence < ready.sourceSequence
            || journal.contentSHA256 != ready.contentSHA256
            || journal.selectionID != ready.selectionID
            || journal.sealedSHA256 != ready.sealedSHA256 {
            throw StaffReplicaDeliveryError.superseded
        }
        try journal.validate(scope: scope, plan: plan, ready: ready,
                             storeJournal: storeJournal, mount: mount)
        guard let activated = try StaffWorkspaceOperationalStoreActivator.loadActivated(
            store: store, scope: scope, planID: planID, check: check) else {
            throw StaffReplicaDeliveryError.pending
        }
        guard activated.journal.selectionID == journal.selectionID,
              activated.journal.contentSHA256 == journal.contentSHA256,
              activated.journal.sourceSequence == journal.sourceSequence,
              activated.journal.recordCount == journal.recordCount,
              activated.journal.operationalWorkspaceReady == false,
              activated.plan.operationalWorkspaceReady == false else {
            throw StaffReplicaDeliveryError.changed
        }
        return StaffWorkspaceOperationalHostedStore(journal: journal, activated: activated)
    }
}
