import Foundation
import CloudKit
import Testing
@testable import GunnAire_Ops

@MainActor
struct CloudKitStaffSharingTests {
    let companyID = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!
    let replicaID = UUID(uuidString: "a1000000-0000-4000-8000-000000000002")!
    let shareID = UUID(uuidString: "a1000000-0000-4000-8000-000000000003")!
    let ownerName = "_test-owner-record"
    let participantName = "_test-staff-record"
    let instant = "2026-09-09T00:00:00Z"
    var now: Date { CompanyWorkspaceClock.parse(instant)! }
    var ownerHash: String { CloudKitStaffSharePlan.accountHash(recordName: ownerName, environment: "development") }
    var participantHash: String { CloudKitStaffSharePlan.accountHash(recordName: participantName, environment: "development") }
    var workspace: CompanyWorkspaceIdentity {
        .init(companyID: companyID, containerID: GunnAireCloudKit.containerIdentifier, bindings: [
            .init(companyID: companyID, containerID: GunnAireCloudKit.containerIdentifier, environment: "development",
                  replicaID: replicaID, cloudAccountHash: ownerHash, approvedAt: instant)
        ])
    }
    var account: CompanyCloudKitAccount { .init(environment: "development", accountHash: participantHash) }
    var member: BackendAppUserRecord { .init(email: "field.technician@gunnaire.com", role: "Field Technician", isActive: true, createdAt: instant) }

    func plan(_ changes: [String: Any] = [:]) throws -> CloudKitStaffSharePlan {
        let fields: [String: Any] = [
            "protocolVersion": 1, "id": shareID.uuidString.lowercased(), "companyID": companyID.uuidString.lowercased(),
            "containerID": GunnAireCloudKit.containerIdentifier, "environment": "development", "replicaID": replicaID.uuidString.lowercased(),
            "ownerAccountHash": ownerHash, "participantAccountHash": participantHash,
            "memberEmail": member.email, "memberRole": member.role, "memberRevision": String(repeating: "a", count: 64),
            "projectionPolicy": "field-assigned-jobs-v1", "zoneName": "ga-staff-a1000000-0000-4000-8000-000000000004",
            "rootRecordName": "workspace", "shareRecordName": "share-a1000000-0000-4000-8000-000000000005",
            "state": "accepted", "revision": 4, "createdAt": instant, "updatedAt": instant,
            "businessAccessEligible": true, "localCloudKitProofRequired": true, "reviewRequired": false, "cloudKitRevocationRequired": false
        ]
        return try JSONDecoder().decode(CloudKitStaffSharePlan.self, from: JSONSerialization.data(withJSONObject: fields.merging(changes) { _, new in new }))
    }

    func evidence(_ plan: CloudKitStaffSharePlan, owner: String? = nil, participant: String? = nil,
                  zoneName: String? = nil, rootName: String? = "workspace", containerID: String? = nil,
                  role: CKShare.ParticipantRole = .privateUser, status: CKShare.ParticipantAcceptanceStatus = .accepted,
                  permission: CKShare.ParticipantPermission = .readOnly, publicPermission: CKShare.ParticipantPermission = .none,
                  currentRole: CKShare.ParticipantRole? = .privateUser, currentPermission: CKShare.ParticipantPermission? = .readOnly,
                  currentStatus: CKShare.ParticipantAcceptanceStatus? = .accepted) -> CloudKitStaffShareEvidence {
        let owner = owner ?? ownerName
        let zone = CKRecordZone.ID(zoneName: zoneName ?? plan.zoneName, ownerName: owner)
        return .init(containerID: containerID ?? plan.containerID, shareRecordID: .init(recordName: plan.shareRecordName, zoneID: zone),
                     rootRecordID: rootName.map { .init(recordName: $0, zoneID: zone) }, ownerRecordName: owner,
                     shareOwnerRecordName: owner, participantRecordName: participant ?? participantName,
                     participantRole: role, participantStatus: status, participantPermission: permission,
                     publicPermission: publicPermission, currentParticipantRole: currentRole,
                     currentParticipantPermission: currentPermission, currentParticipantStatus: currentStatus)
    }

    @Test func backendPlanRequiresIndependentAppleProofAndCannotSelectLegacyPrivateBinding() throws {
        let plan = try plan()
        try plan.validate(workspace: workspace, now: now)
        #expect(plan.localCloudKitProofRequired)
        #expect(plan.participantAccountHash != workspace.binding(for: plan.environment)?.cloudAccountHash)
        let decoded = try JSONDecoder().decode(CloudKitStaffSharePlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
        #expect(CompanyWorkspaceRequestPolicy.needsWorkspaceProof(path: "/api/workspace/staff-shares"))
    }

    @Test func allFiveBusinessRolesHaveDistinctKnownProjectionPolicies() throws {
        #expect(Set(AppUserRole.allCases.compactMap { CloudKitStaffSharePlan.policy(for: $0.rawValue) }).count == 5)
        #expect(CloudKitStaffSharePlan.policy(for: "Owner") == nil)
        for role in AppUserRole.allCases {
            let value = try plan(["memberRole": role.rawValue, "projectionPolicy": CloudKitStaffSharePlan.policy(for: role.rawValue)!])
            try value.validate(workspace: workspace, now: now)
        }
    }

    @Test func malformedForeignOrBroaderPlansFailClosed() throws {
        let changes: [[String: Any]] = [
            ["protocolVersion": 2], ["companyID": UUID().uuidString], ["replicaID": UUID().uuidString],
            ["containerID": "iCloud.other.company"], ["environment": "production"], ["ownerAccountHash": participantHash],
            ["participantAccountHash": ownerHash], ["participantAccountHash": "X"], ["memberRevision": "x"],
            ["memberEmail": "field.technician@gunnaire.com\n"], ["memberRole": "Admin"], ["projectionPolicy": "all-records"],
            ["zoneName": "com.apple.coredata.cloudkit.zone"], ["zoneName": "ga-staff-../foreign"],
            ["shareRecordName": CKRecordNameZoneWideShare], ["rootRecordName": "privateStore"],
            ["localCloudKitProofRequired": false], ["reviewRequired": true], ["cloudKitRevocationRequired": true],
            ["revision": 0], ["revision": 2], ["state": "approved"], ["state": "unknown"],
            ["updatedAt": "not-a-date"], ["createdAt": "2026-09-10T00:00:00Z"], ["updatedAt": "2026-09-09T00:05:01Z"]
        ]
        for change in changes {
            let value = try plan(change)
            #expect(throws: CloudKitStaffSharingError.self) { try value.validate(workspace: workspace, now: now) }
        }
    }

    @Test func originalReplyCanAdvanceOrLoseEligibilityButNeverReplaceOrResurrect() throws {
        let approved = try plan(["state": "approved", "revision": 2, "businessAccessEligible": false])
        let accepted = try plan()
        try accepted.validateSuccessor(of: approved, workspace: workspace, now: now)
        let revoked = try plan(["state": "revoked", "revision": 5, "businessAccessEligible": false, "cloudKitRevocationRequired": true])
        try revoked.validateSuccessor(of: accepted, workspace: workspace, now: now)
        let changedUser = try plan(["businessAccessEligible": false, "reviewRequired": true, "cloudKitRevocationRequired": true])
        try changedUser.validateSuccessor(of: accepted, workspace: workspace, now: now)
        for replacement in [try plan(["state": "accepted", "revision": 6]), try plan(["revision": 7, "participantAccountHash": String(repeating: "b", count: 64)]),
                            try plan(["revision": 7, "zoneName": "ga-staff-a1000000-0000-4000-8000-000000000099"])] {
            #expect(throws: CloudKitStaffSharingError.self) { try replacement.validateSuccessor(of: revoked, workspace: workspace, now: now) }
        }
        #expect(throws: CloudKitStaffSharingError.self) { try approved.validateSuccessor(of: accepted, workspace: workspace, now: now) }
    }

    @Test func exactAcceptedReadOnlyPrivateParticipantVerifiesItsOwnSharedZone() throws {
        let plan = try plan()
        let zone = try evidence(plan).verify(plan: plan, workspace: workspace, account: account, member: member, requiresAccepted: true, now: now)
        #expect(zone.zoneName == plan.zoneName)
        #expect(zone.ownerName == ownerName)
        #expect(zone.ownerName != CKCurrentUserDefaultName)
    }

    @Test func pendingInvitationIsNotAnAcceptedWorkspace() throws {
        let value = try plan(["state": "invited", "revision": 3, "businessAccessEligible": false])
        let proof = evidence(value, status: .pending, currentStatus: .pending)
        _ = try proof.verify(plan: value, workspace: workspace, account: account, member: member, requiresAccepted: false, now: now)
        #expect(throws: CloudKitStaffSharingError.self) {
            try proof.verify(plan: value, workspace: workspace, account: account, member: member, requiresAccepted: true, now: now)
        }
    }

    @Test func missingForeignPublicWritableRemovedAndCloudKitAdminParticipantsAreRejected() throws {
        let value = try plan()
        let invalid = [
            evidence(value, owner: "_another-owner"), evidence(value, owner: CKCurrentUserDefaultName),
            evidence(value, participant: "_another-staff"), evidence(value, participant: ""),
            evidence(value, zoneName: "another-zone"), evidence(value, rootName: nil), evidence(value, rootName: "other"),
            evidence(value, containerID: "iCloud.foreign"), evidence(value, role: .publicUser), evidence(value, role: .owner),
            evidence(value, role: .administrator), evidence(value, permission: .readWrite), evidence(value, publicPermission: .readOnly),
            evidence(value, publicPermission: .readWrite), evidence(value, status: .removed), evidence(value, status: .unknown),
            evidence(value, currentRole: nil), evidence(value, currentRole: .administrator), evidence(value, currentPermission: .readWrite),
            evidence(value, currentStatus: .removed)
        ]
        for proof in invalid {
            #expect(throws: CloudKitStaffSharingError.self) {
                try proof.verify(plan: value, workspace: workspace, account: account, member: member, requiresAccepted: true, now: now)
            }
        }
    }

    @Test func actualAppleAccountEnvironmentAndCurrentBusinessRoleMustAllMatch() throws {
        let value = try plan()
        for current in [CompanyCloudKitAccount(environment: "production", accountHash: participantHash),
                        CompanyCloudKitAccount(environment: "development", accountHash: ownerHash)] {
            #expect(throws: CloudKitStaffSharingError.self) {
                try evidence(value).verify(plan: value, workspace: workspace, account: current, member: member, requiresAccepted: true, now: now)
            }
        }
        for user in [BackendAppUserRecord(email: member.email, role: "Standard", isActive: true, createdAt: instant),
                     BackendAppUserRecord(email: member.email, role: member.role, isActive: false, createdAt: instant),
                     BackendAppUserRecord(email: "other@gunnaire.com", role: member.role, isActive: true, createdAt: instant)] {
            #expect(throws: CloudKitStaffSharingError.self) {
                try evidence(value).verify(plan: value, workspace: workspace, account: account, member: user, requiresAccepted: true, now: now)
            }
        }
    }

    @Test func ownerDraftIsAnEmptyPrivateHierarchyWithNoCustomerOrFinancialFields() throws {
        let value = try plan(["state": "approved", "revision": 2, "businessAccessEligible": false])
        let ownerAccount = CompanyCloudKitAccount(environment: "development", accountHash: ownerHash)
        let (zone, root, share) = try CloudKitStaffShareRecords.ownerDraft(plan: value, workspace: workspace, account: ownerAccount, now: now)
        #expect(zone.zoneID.zoneName == value.zoneName)
        #expect(root.recordType == "GAStaffWorkspace")
        #expect(share.publicPermission == .none)
        #expect(share.recordID.recordName == value.shareRecordName)
        #expect(share.url == nil)
        try CloudKitStaffShareRecords.verifyRoot(root, plan: value, zone: zone.zoneID)
        #expect(throws: CloudKitStaffSharingError.self) {
            try CloudKitStaffShareRecords.ownerDraft(plan: value, workspace: workspace, account: account, now: now)
        }
        root["projectionPolicy"] = "admin-operations-v1" as CKRecordValue
        #expect(throws: CloudKitStaffSharingError.self) { try CloudKitStaffShareRecords.verifyRoot(root, plan: value, zone: zone.zoneID) }
        root["projectionPolicy"] = value.projectionPolicy as CKRecordValue
        root["customerList"] = "must never be present in the bootstrap root" as CKRecordValue
        #expect(throws: CloudKitStaffSharingError.self) { try CloudKitStaffShareRecords.verifyRoot(root, plan: value, zone: zone.zoneID) }
    }
}
