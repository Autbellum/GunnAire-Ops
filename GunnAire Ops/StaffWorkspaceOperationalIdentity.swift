import Foundation

/// Fail-closed staff projection operational identity bind after host-v1.
///
/// Journals `staff-workspace-operational-identity-v1` with `state = bound` and
/// `operationalWorkspaceReady = false` (intermediate proof — only ready-v1 and
/// host-v1 flip ready true). Binds HostedStore presentation to the signed
/// CloudKit participant account + this device installation so a leaked/copied
/// hosted journal cannot present on the wrong account or device. Never unlocks
/// the owner ModelContainer, never calls owner `ModelCodec.make`, and never
/// rewrites mount payload bytes.
struct StaffWorkspaceOperationalIdentityJournal: Codable, Equatable {
    static let schema = "staff-workspace-operational-identity-v1"
    let schema: String
    let scope: CloudKitStaffSetupScope
    let planID: UUID
    let selectionID: String
    let sourceSequence: Int
    let contentSHA256: String
    let sealedSHA256: String
    let recordCount: Int
    let environment: String
    let participantAccountHash: String
    let deviceFingerprint: String
    let state: String
    let operationalWorkspaceReady: Bool

    init(scope: CloudKitStaffSetupScope, planID: UUID, selectionID: String,
         sourceSequence: Int, contentSHA256: String, sealedSHA256: String,
         recordCount: Int, environment: String, participantAccountHash: String,
         deviceFingerprint: String) throws {
        guard CloudKitStaffSetupPolicy.canonicalID(selectionID),
              (1...2_147_483_647).contains(sourceSequence),
              JobBillingAssignmentSnapshot.validConnectionRevision(contentSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(sealedSHA256),
              JobBillingAssignmentSnapshot.validConnectionRevision(participantAccountHash),
              JobBillingAssignmentSnapshot.validConnectionRevision(deviceFingerprint),
              (0...20_000).contains(recordCount),
              !environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              environment.count <= 64,
              scope.environment == environment,
              scope.accountHash == participantAccountHash else {
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
        self.environment = environment
        self.participantAccountHash = participantAccountHash
        self.deviceFingerprint = deviceFingerprint
        state = "bound"
        operationalWorkspaceReady = false
    }

    func validate(scope: CloudKitStaffSetupScope, plan: CloudKitStaffSharePlan,
                  hosted: StaffWorkspaceOperationalHostJournal,
                  account: CompanyCloudKitAccount,
                  deviceFingerprint: String) throws {
        guard schema == Self.schema, state == "bound", operationalWorkspaceReady == false,
              self.scope == scope, planID == plan.id,
              selectionID == hosted.selectionID,
              sourceSequence == hosted.sourceSequence,
              contentSHA256 == hosted.contentSHA256,
              sealedSHA256 == hosted.sealedSHA256,
              recordCount == hosted.recordCount,
              hosted.state == "hosted",
              hosted.operationalWorkspaceReady == true,
              environment == account.environment,
              participantAccountHash == account.accountHash,
              self.deviceFingerprint == deviceFingerprint,
              participantAccountHash == plan.participantAccountHash,
              environment == plan.environment,
              JobBillingAssignmentSnapshot.validConnectionRevision(self.deviceFingerprint),
              JobBillingAssignmentSnapshot.validConnectionRevision(participantAccountHash),
              plan.state == "accepted",
              plan.businessAccessEligible,
              !plan.reviewRequired,
              !plan.cloudKitRevocationRequired else {
            throw StaffReplicaDeliveryError.storage
        }
    }
}

/// Durable journal helpers for staff projection operational identity bind.
enum StaffWorkspaceOperationalIdentityStore {
    static let installationFingerprintPrefix = "gunnaire-staff-installation-v1\n"

    static func key(_ scope: CloudKitStaffSetupScope, _ plan: UUID) -> String {
        "full-staff-content-identity-v1\n" + scope.key + "\n" + plan.uuidString.lowercased()
    }

    /// Stable 64-hex device fingerprint from an installation UUID (no UIKit).
    static func deviceFingerprint(installationID: UUID) -> String {
        CompanyWorkspaceSession.digest(installationFingerprintPrefix + installationID.uuidString.lowercased())
    }

    static func loadJournal(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws
    -> StaffWorkspaceOperationalIdentityJournal? {
        do {
            guard let bytes = try store.read(key(scope, plan)) else { return nil }
            guard bytes.count <= 8192 else { throw StaffReplicaDeliveryError.storage }
            let journal = try StaffWorkspacePublicationContract.decode(
                StaffWorkspaceOperationalIdentityJournal.self, from: bytes, maximum: 8192)
            guard journal.schema == StaffWorkspaceOperationalIdentityJournal.schema,
                  journal.state == "bound",
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

    private static func requireEligiblePlan(_ plan: CloudKitStaffSharePlan, planID: UUID) throws {
        guard plan.id == planID,
              plan.state == "accepted",
              plan.businessAccessEligible,
              !plan.reviewRequired,
              !plan.cloudKitRevocationRequired else {
            throw StaffReplicaDeliveryError.changed
        }
    }

    private static func requireAccount(_ account: CompanyCloudKitAccount,
                                       plan: CloudKitStaffSharePlan,
                                       deviceFingerprint: String) throws {
        guard JobBillingAssignmentSnapshot.validConnectionRevision(deviceFingerprint),
              JobBillingAssignmentSnapshot.validConnectionRevision(account.accountHash),
              account.accountHash == plan.participantAccountHash,
              account.environment == plan.environment else {
            throw StaffReplicaDeliveryError.access
        }
    }

    /// Fail-closed identity bind after an already-open HostedStore (or matching
    /// host journal + digests). Requires plan accepted/eligible, account hash +
    /// environment match plan participant, and a 64-hex device fingerprint.
    /// Idempotent for the same head+identity; never rewrites mount payload bytes;
    /// never flips `operationalWorkspaceReady`.
    @MainActor
    static func bind(plan: CloudKitStaffSharePlan,
                     store: SharedTimeLocalStore,
                     scope: CloudKitStaffSetupScope,
                     planID: UUID,
                     account: CompanyCloudKitAccount,
                     deviceFingerprint: String,
                     hosted: StaffWorkspaceOperationalHostedStore? = nil,
                     check: () throws -> Void = {}) throws
    -> StaffWorkspaceOperationalIdentityJournal {
        try check()
        try requireEligiblePlan(plan, planID: planID)
        try requireAccount(account, plan: plan, deviceFingerprint: deviceFingerprint)

        let hostJournal: StaffWorkspaceOperationalHostJournal
        if let hosted {
            try StaffWorkspaceOperationalPresentation.requireHosted(hosted)
            guard hosted.journal.planID == planID,
                  hosted.journal.scope == scope else {
                throw StaffReplicaDeliveryError.changed
            }
            hostJournal = hosted.journal
        } else if let loaded = try StaffWorkspaceOperationalHostStore.load(
            plan: plan, store: store, scope: scope, planID: planID, check: check) {
            try StaffWorkspaceOperationalPresentation.requireHosted(loaded)
            hostJournal = loaded.journal
        } else {
            throw StaffReplicaDeliveryError.pending
        }

        let next = try StaffWorkspaceOperationalIdentityJournal(
            scope: scope, planID: planID, selectionID: hostJournal.selectionID,
            sourceSequence: hostJournal.sourceSequence, contentSHA256: hostJournal.contentSHA256,
            sealedSHA256: hostJournal.sealedSHA256, recordCount: hostJournal.recordCount,
            environment: account.environment, participantAccountHash: account.accountHash,
            deviceFingerprint: deviceFingerprint)
        try next.validate(scope: scope, plan: plan, hosted: hostJournal,
                          account: account, deviceFingerprint: deviceFingerprint)

        if let existing = try loadJournal(store: store, scope: scope, plan: planID) {
            if existing.selectionID == next.selectionID,
               existing.contentSHA256 == next.contentSHA256,
               existing.sealedSHA256 == next.sealedSHA256,
               existing.sourceSequence == next.sourceSequence,
               existing.recordCount == next.recordCount,
               existing.participantAccountHash == next.participantAccountHash,
               existing.environment == next.environment,
               existing.deviceFingerprint == next.deviceFingerprint {
                try existing.validate(scope: scope, plan: plan, hosted: hostJournal,
                                      account: account, deviceFingerprint: deviceFingerprint)
                guard existing.operationalWorkspaceReady == false,
                      existing.state == "bound" else {
                    throw StaffReplicaDeliveryError.storage
                }
                return existing
            }
            if existing.participantAccountHash != next.participantAccountHash
                || existing.deviceFingerprint != next.deviceFingerprint
                || existing.environment != next.environment {
                throw StaffReplicaDeliveryError.changed
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

        // Prior journals remain historical proofs — identity stays ready=false;
        // host/ready stay true; mount payload bytes unchanged.
        guard let confirmedHost = try StaffWorkspaceOperationalHostStore.loadJournal(
                store: store, scope: scope, plan: planID),
              confirmedHost == hostJournal,
              confirmedHost.operationalWorkspaceReady == true,
              confirmedHost.state == "hosted",
              let confirmedReady = try StaffWorkspaceOperationalReadyStore.load(
                store: store, scope: scope, plan: planID),
              confirmedReady.operationalWorkspaceReady == true,
              confirmedReady.state == "ready",
              let confirmedStore = try StaffWorkspaceOperationalStoreActivator.loadJournal(
                store: store, scope: scope, plan: planID),
              confirmedStore.operationalWorkspaceReady == false,
              let confirmed = try loadJournal(store: store, scope: scope, plan: planID),
              confirmed == next,
              confirmed.operationalWorkspaceReady == false,
              confirmed.state == "bound" else {
            throw StaffReplicaDeliveryError.storage
        }
        try confirmed.validate(scope: scope, plan: plan, hosted: confirmedHost,
                               account: account, deviceFingerprint: deviceFingerprint)
        return confirmed
    }

    /// Reload the durable identity journal, or nil when absent.
    static func load(store: SharedTimeLocalStore, scope: CloudKitStaffSetupScope, plan: UUID) throws
    -> StaffWorkspaceOperationalIdentityJournal? {
        try loadJournal(store: store, scope: scope, plan: plan)
    }
}
