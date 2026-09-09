import Foundation
import CloudKit

enum CloudKitStaffSharingError: Error, LocalizedError, Equatable {
    case invalid, changed, account, permission, review, storage, unavailable, access
    var errorDescription: String? {
        switch self {
        case .invalid: "This staff invitation could not be verified. Ask the administrator to review the original request."
        case .changed: "The business, account or invitation changed. Reopen the original invitation; existing work is retained."
        case .account: "This invitation is for a different iCloud account. No saved workspace was opened or replaced."
        case .permission: "This CloudKit share has unexpected access permissions. Ask the administrator to review it."
        case .review: "Staff sharing needs administrator review before this device can open it."
        case .storage: "Saved iCloud setup could not be verified on this device. It was retained; ask the administrator to review it before reinstalling."
        case .unavailable: "iCloud setup could not be confirmed. Reopen the original request and try recovery when connected."
        case .access: "Sign in again with your approved business account and reopen iCloud setup."
        }
    }
}

/// A server authorization plan, never proof that Apple has granted access.
/// Deliberately not accepted by CompanyWorkspaceStore or its private-store gate.
struct CloudKitStaffSharePlan: Codable, Equatable {
    let protocolVersion: Int
    let id: UUID
    let companyID: UUID
    let containerID: String
    let environment: String
    let replicaID: UUID
    let ownerAccountHash: String
    let participantAccountHash: String
    let memberEmail: String
    let memberRole: String
    let memberRevision: String
    let projectionPolicy: String
    let zoneName: String
    let rootRecordName: String
    let shareRecordName: String
    let state: String
    let revision: Int
    let createdAt: String
    let updatedAt: String
    let businessAccessEligible: Bool
    let localCloudKitProofRequired: Bool
    let reviewRequired: Bool
    let cloudKitRevocationRequired: Bool
    let participantIdentityAvailable: Bool?

    static func policy(for role: String) -> String? {
        switch AppUserRole(rawValue: role) {
        case .admin: "admin-operations-v1"
        case .dispatcher: "dispatch-operations-v1"
        case .fieldTechnician: "field-assigned-jobs-v1"
        case .accounting: "accounting-operations-v1"
        case .standard: "standard-self-v1"
        case nil: nil
        }
    }

    static func accountHash(recordName: String, environment: String) -> String {
        CompanyWorkspaceSession.digest("gunnaire-cloudkit-account-v1\n\(GunnAireCloudKit.containerIdentifier)\n\(environment)\n\(recordName)")
    }

    private static func namedUUID(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
    }

    func validate(workspace: CompanyWorkspaceIdentity, now: Date = Date()) throws {
        guard let binding = workspace.binding(for: environment), companyID == workspace.companyID,
              containerID == workspace.containerID, replicaID == binding.replicaID,
              ownerAccountHash == binding.cloudAccountHash else { throw CloudKitStaffSharingError.changed }
        guard protocolVersion == 1, (1...2_147_483_647).contains(revision),
              Self.policy(for: memberRole) == projectionPolicy, SharedTimeError.validEmail(memberEmail),
              JobBillingAssignmentSnapshot.validConnectionRevision(participantAccountHash), participantAccountHash != ownerAccountHash,
              JobBillingAssignmentSnapshot.validConnectionRevision(memberRevision),
              Self.namedUUID(zoneName, prefix: "ga-staff-"), Self.namedUUID(shareRecordName, prefix: "share-"),
              rootRecordName == "workspace", localCloudKitProofRequired,
              let created = SharedTimeError.date(createdAt), let updated = SharedTimeError.date(updatedAt),
              created <= updated, updated <= now.addingTimeInterval(300),
              ["requested", "approved", "invited", "accepted", "revoked"].contains(state),
              revision >= ["requested": 1, "approved": 2, "invited": 3, "accepted": 4, "revoked": 2][state, default: 2_147_483_647],
              state != "requested" || revision == 1,
              !businessAccessEligible || (state == "accepted" && !reviewRequired && !cloudKitRevocationRequired)
        else { throw CloudKitStaffSharingError.invalid }
    }

    /// A recovered reply may advance state, but must never substitute a zone,
    /// participant, policy or role, or resurrect a revoked invitation.
    func validateSuccessor(of prior: Self, workspace: CompanyWorkspaceIdentity, now: Date = Date()) throws {
        try validate(workspace: workspace, now: now)
        try prior.validate(workspace: workspace, now: now)
        guard id == prior.id, companyID == prior.companyID, containerID == prior.containerID,
              environment == prior.environment, replicaID == prior.replicaID, ownerAccountHash == prior.ownerAccountHash,
              participantAccountHash == prior.participantAccountHash, memberEmail == prior.memberEmail,
              memberRole == prior.memberRole, memberRevision == prior.memberRevision, projectionPolicy == prior.projectionPolicy,
              zoneName == prior.zoneName, rootRecordName == prior.rootRecordName, shareRecordName == prior.shareRecordName,
              createdAt == prior.createdAt, revision >= prior.revision,
              participantIdentityAvailable == prior.participantIdentityAvailable,
              let before = SharedTimeError.date(prior.updatedAt), let after = SharedTimeError.date(updatedAt), after >= before
        else { throw CloudKitStaffSharingError.changed }
        let order = ["requested": 0, "approved": 1, "invited": 2, "accepted": 3, "revoked": 4]
        guard order[state, default: -1] >= order[prior.state, default: -1],
              revision != prior.revision || (state == prior.state && updatedAt == prior.updatedAt)
        else { throw CloudKitStaffSharingError.changed }
        // Eligibility can fall without a share-row revision when a backend
        // user is deactivated. The caller must honor the freshest response.
    }
}

/// Ephemeral values read from Apple's CKShare.Metadata, not a Codable receipt
/// or a user-supplied assertion. No raw iCloud identifiers are persisted here.
struct CloudKitStaffShareEvidence {
    let containerID: String
    let shareRecordID: CKRecord.ID
    let rootRecordID: CKRecord.ID?
    let ownerRecordName: String?
    let shareOwnerRecordName: String?
    let participantRecordName: String?
    let participantRole: CKShare.ParticipantRole
    let participantStatus: CKShare.ParticipantAcceptanceStatus
    let participantPermission: CKShare.ParticipantPermission
    let publicPermission: CKShare.ParticipantPermission
    let currentParticipantRole: CKShare.ParticipantRole?
    let currentParticipantPermission: CKShare.ParticipantPermission?
    let currentParticipantStatus: CKShare.ParticipantAcceptanceStatus?

    init(metadata: CKShare.Metadata) {
        self.init(containerID: metadata.containerIdentifier, shareRecordID: metadata.share.recordID,
                  rootRecordID: metadata.hierarchicalRootRecordID,
                  ownerRecordName: metadata.ownerIdentity.userRecordID?.recordName,
                  shareOwnerRecordName: metadata.share.owner.userIdentity.userRecordID?.recordName,
                  participantRecordName: metadata.share.currentUserParticipant?.userIdentity.userRecordID?.recordName,
                  participantRole: metadata.participantRole, participantStatus: metadata.participantStatus,
                  participantPermission: metadata.participantPermission, publicPermission: metadata.share.publicPermission,
                  currentParticipantRole: metadata.share.currentUserParticipant?.role,
                  currentParticipantPermission: metadata.share.currentUserParticipant?.permission,
                  currentParticipantStatus: metadata.share.currentUserParticipant?.acceptanceStatus)
    }

    // Explicit snapshot initializer supports unsigned, account-free tests.
    init(containerID: String, shareRecordID: CKRecord.ID, rootRecordID: CKRecord.ID?, ownerRecordName: String?,
         shareOwnerRecordName: String?, participantRecordName: String?, participantRole: CKShare.ParticipantRole,
         participantStatus: CKShare.ParticipantAcceptanceStatus, participantPermission: CKShare.ParticipantPermission,
         publicPermission: CKShare.ParticipantPermission, currentParticipantRole: CKShare.ParticipantRole?,
         currentParticipantPermission: CKShare.ParticipantPermission?, currentParticipantStatus: CKShare.ParticipantAcceptanceStatus?) {
        self.containerID = containerID; self.shareRecordID = shareRecordID; self.rootRecordID = rootRecordID
        self.ownerRecordName = ownerRecordName; self.shareOwnerRecordName = shareOwnerRecordName
        self.participantRecordName = participantRecordName; self.participantRole = participantRole
        self.participantStatus = participantStatus; self.participantPermission = participantPermission
        self.publicPermission = publicPermission; self.currentParticipantRole = currentParticipantRole
        self.currentParticipantPermission = currentParticipantPermission
        self.currentParticipantStatus = currentParticipantStatus
    }

    func verify(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity, account: CompanyCloudKitAccount,
                member: BackendAppUserRecord, requiresAccepted: Bool, now: Date = Date()) throws -> CKRecordZone.ID {
        try plan.validate(workspace: workspace, now: now)
        guard member.isActive, member.email == plan.memberEmail, member.role == plan.memberRole,
              !plan.reviewRequired, !plan.cloudKitRevocationRequired,
              ["invited", "accepted"].contains(plan.state),
              !requiresAccepted || (plan.state == "accepted" && plan.businessAccessEligible)
        else { throw CloudKitStaffSharingError.review }
        guard account.environment == plan.environment, account.accountHash == plan.participantAccountHash,
              let ownerRecordName, !ownerRecordName.isEmpty, ownerRecordName != CKCurrentUserDefaultName,
              shareOwnerRecordName == ownerRecordName,
              CloudKitStaffSharePlan.accountHash(recordName: ownerRecordName, environment: account.environment) == plan.ownerAccountHash,
              let participantRecordName, !participantRecordName.isEmpty, participantRecordName != CKCurrentUserDefaultName,
              CloudKitStaffSharePlan.accountHash(recordName: participantRecordName, environment: account.environment) == account.accountHash
        else { throw CloudKitStaffSharingError.account }
        let zone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: ownerRecordName)
        guard containerID == plan.containerID, shareRecordID == CKRecord.ID(recordName: plan.shareRecordName, zoneID: zone),
              rootRecordID == CKRecord.ID(recordName: plan.rootRecordName, zoneID: zone)
        else { throw CloudKitStaffSharingError.changed }
        guard publicPermission == .none, participantRole == .privateUser, participantPermission == .readOnly,
              currentParticipantRole == .privateUser, currentParticipantPermission == .readOnly,
              currentParticipantStatus == participantStatus,
              participantStatus == .accepted || (!requiresAccepted && participantStatus == .pending)
        else { throw CloudKitStaffSharingError.permission }
        return zone
    }
}

enum CloudKitStaffShareRecords {
    static let rootType = "GAStaffWorkspace"

    /// Constructs an empty, isolated hierarchy. No model export, container
    /// attachment, CloudKit write, invitation send or automatic acceptance.
    static func ownerDraft(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                           account: CompanyCloudKitAccount, now: Date = Date()) throws -> (CKRecordZone, CKRecord, CKShare) {
        try plan.validate(workspace: workspace, now: now)
        guard plan.state == "approved", !plan.reviewRequired, !plan.cloudKitRevocationRequired,
              account.environment == plan.environment, account.accountHash == plan.ownerAccountHash
        else { throw CloudKitStaffSharingError.review }
        let zone = CKRecordZone(zoneName: plan.zoneName)
        let root = CKRecord(recordType: rootType, recordID: .init(recordName: plan.rootRecordName, zoneID: zone.zoneID))
        root["protocolVersion"] = NSNumber(value: 1)
        root["companyID"] = plan.companyID.uuidString.lowercased() as CKRecordValue
        root["replicaID"] = plan.replicaID.uuidString.lowercased() as CKRecordValue
        root["membershipID"] = plan.id.uuidString.lowercased() as CKRecordValue
        root["memberRevision"] = plan.memberRevision as CKRecordValue
        root["projectionPolicy"] = plan.projectionPolicy as CKRecordValue
        let share = CKShare(rootRecord: root, shareID: .init(recordName: plan.shareRecordName, zoneID: zone.zoneID))
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "GunnAire Ops staff workspace" as CKRecordValue
        return (zone, root, share)
    }

    static func verifyRoot(_ root: CKRecord, plan: CloudKitStaffSharePlan, zone: CKRecordZone.ID) throws {
        guard root.recordType == rootType, zone.zoneName == plan.zoneName,
              Set(root.allKeys()) == ["protocolVersion", "companyID", "replicaID", "membershipID", "memberRevision", "projectionPolicy"],
              root.recordID == CKRecord.ID(recordName: plan.rootRecordName, zoneID: zone),
              root["protocolVersion"] as? NSNumber == NSNumber(value: 1),
              root["companyID"] as? String == plan.companyID.uuidString.lowercased(),
              root["replicaID"] as? String == plan.replicaID.uuidString.lowercased(),
              root["membershipID"] as? String == plan.id.uuidString.lowercased(),
              root["memberRevision"] as? String == plan.memberRevision,
              root["projectionPolicy"] as? String == plan.projectionPolicy
        else { throw CloudKitStaffSharingError.changed }
    }
}
