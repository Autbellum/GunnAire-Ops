import Foundation
import CloudKit

/// Apple operations use exact server-reserved IDs. Never touches SwiftData's
/// internal CloudKit zone or broadens an existing share's participant list.
@MainActor struct CloudKitStaffRemote {
    typealias Authorize = @MainActor () async throws -> Void
    let invitation: (CloudKitStaffSharePlan, CompanyWorkspaceIdentity, CompanyCloudKitAccount, String, Authorize) async throws -> URL
    let accept: (CloudKitStaffSharePlan, CompanyWorkspaceIdentity, CompanyCloudKitAccount, BackendAppUserRecord, URL, Authorize) async throws -> Void
    let cleanup: (CloudKitStaffSharePlan, CompanyWorkspaceIdentity, CompanyCloudKitAccount, Authorize) async throws -> Void

    static var live: Self {
        .init(invitation: createOrRecoverInvitation, accept: acceptOrRecoverInvitation, cleanup: removeOrRecoverShare)
    }

    private static func container() throws -> CKContainer {
        guard !GunnAireCloudKit.usesTestDatabase else { throw CloudKitStaffSharingError.unavailable }
        return CKContainer(identifier: GunnAireCloudKit.containerIdentifier)
    }

    private static func optionalRecord(_ result: Result<CKRecord, Error>?) throws -> CKRecord? {
        guard let result else { throw CloudKitStaffSharingError.invalid }
        do { return try result.get() }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound { return nil }
    }

    static func verifyOwnerShare(_ share: CKShare, root: CKRecord, plan: CloudKitStaffSharePlan,
                                 account: CompanyCloudKitAccount, enforceParticipant: Bool) throws -> URL? {
        guard account.accountHash == plan.ownerAccountHash, account.environment == plan.environment,
              share.recordID.zoneID == root.recordID.zoneID, share.recordID.recordName == plan.shareRecordName,
              root.share?.recordID == share.recordID,
              let owner = share.owner.userIdentity.userRecordID?.recordName,
              CloudKitStaffSharePlan.accountHash(recordName: owner, environment: plan.environment) == account.accountHash,
              share.currentUserParticipant?.role == .owner else { throw CloudKitStaffSharingError.changed }
        try CloudKitStaffShareRecords.verifyRoot(root, plan: plan, zone: root.recordID.zoneID)
        if enforceParticipant {
            guard share.publicPermission == .none, share.participants.count == 2 else { throw CloudKitStaffSharingError.permission }
            let staff = share.participants.filter { $0.role != .owner }
            guard staff.count == 1, let participant = staff.first, participant.role == .privateUser,
                  participant.permission == .readOnly, [.pending, .accepted].contains(participant.acceptanceStatus),
                  let name = participant.userIdentity.userRecordID?.recordName,
                  CloudKitStaffSharePlan.accountHash(recordName: name, environment: plan.environment) == plan.participantAccountHash,
                  let url = share.url, CloudKitStaffSetupPolicy.invitationURL(url)
            else { throw CloudKitStaffSharingError.permission }
        }
        return share.url
    }

    private static func readOwner(database: CKDatabase, plan: CloudKitStaffSharePlan, account: CompanyCloudKitAccount,
                                  authorize: Authorize) async throws -> (CKRecord?, CKShare?) {
        let zone = CKRecordZone.ID(zoneName: plan.zoneName, ownerName: CKCurrentUserDefaultName)
        let rootID = CKRecord.ID(recordName: plan.rootRecordName, zoneID: zone)
        let shareID = CKRecord.ID(recordName: plan.shareRecordName, zoneID: zone)
        try await authorize()
        let zones = try await database.recordZones(for: [zone])
        try await authorize()
        guard zones.count == 1, let existingZone = zones[zone] else { throw CloudKitStaffSharingError.invalid }
        do {
            guard try existingZone.get().zoneID == zone else { throw CloudKitStaffSharingError.changed }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            return (nil, nil)
        }
        try await authorize()
        let result = try await database.records(for: [rootID, shareID])
        try await authorize()
        guard Set(result.keys) == [rootID, shareID] else { throw CloudKitStaffSharingError.invalid }
        let root = try optionalRecord(result[rootID]), rawShare = try optionalRecord(result[shareID])
        if let root { try CloudKitStaffShareRecords.verifyRoot(root, plan: plan, zone: zone) }
        guard rawShare == nil || rawShare is CKShare, root != nil || rawShare == nil else { throw CloudKitStaffSharingError.changed }
        return (root, rawShare as? CKShare)
    }

    private static func createOrRecoverInvitation(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                                                   account: CompanyCloudKitAccount, recordName: String,
                                                   authorize: Authorize) async throws -> URL {
        try plan.validate(workspace: workspace)
        guard account.accountHash == plan.ownerAccountHash, account.environment == plan.environment,
              plan.participantIdentityAvailable == true, !plan.reviewRequired, !plan.cloudKitRevocationRequired,
              ["approved", "invited", "accepted"].contains(plan.state),
              CloudKitStaffSharePlan.accountHash(recordName: recordName, environment: plan.environment) == plan.participantAccountHash
        else { throw CloudKitStaffSharingError.review }
        let container = try container(), database = container.privateCloudDatabase
        let (oldRoot, oldShare) = try await readOwner(database: database, plan: plan, account: account, authorize: authorize)
        if let oldRoot, let oldShare {
            guard let url = try verifyOwnerShare(oldShare, root: oldRoot, plan: plan, account: account, enforceParticipant: true)
            else { throw CloudKitStaffSharingError.invalid }
            return url
        }
        // A previously invited/accepted share that disappeared is not silently
        // recreated. A fresh invitation requires reviewed revocation/re-enrollment.
        guard plan.state == "approved", oldRoot == nil, oldShare == nil else { throw CloudKitStaffSharingError.review }
        let userID = CKRecord.ID(recordName: recordName)
        try await authorize()
        let people = try await container.shareParticipants(forUserRecordIDs: [userID])
        try await authorize()
        guard people.count == 1, let result = people[userID] else { throw CloudKitStaffSharingError.invalid }
        let person = try result.get()
        guard person.userIdentity.hasiCloudAccount, person.userIdentity.userRecordID?.recordName == recordName else {
            throw CloudKitStaffSharingError.account
        }
        person.role = .privateUser; person.permission = .readOnly
        let (zone, root, share) = try CloudKitStaffShareRecords.ownerDraft(plan: plan, workspace: workspace, account: account)
        share.addParticipant(person)
        try await authorize()
        let zones = try await database.modifyRecordZones(saving: [zone], deleting: [])
        try await authorize()
        guard zones.saveResults.count == 1, zones.deleteResults.isEmpty, let savedZone = zones.saveResults[zone.zoneID] else {
            throw CloudKitStaffSharingError.invalid
        }
        guard try savedZone.get().zoneID == zone.zoneID else { throw CloudKitStaffSharingError.changed }
        try await authorize()
        let records = try await database.modifyRecords(saving: [root, share], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        try await authorize()
        guard Set(records.saveResults.keys) == [root.recordID, share.recordID], records.deleteResults.isEmpty else {
            throw CloudKitStaffSharingError.invalid
        }
        for result in records.saveResults.values { _ = try result.get() }
        let (confirmedRoot, confirmedShare) = try await readOwner(database: database, plan: plan, account: account, authorize: authorize)
        guard let confirmedRoot, let confirmedShare,
              let url = try verifyOwnerShare(confirmedShare, root: confirmedRoot, plan: plan, account: account, enforceParticipant: true)
        else { throw CloudKitStaffSharingError.invalid }
        return url
    }

    private static func metadata(container: CKContainer, url: URL, authorize: Authorize) async throws -> CKShare.Metadata {
        guard CloudKitStaffSetupPolicy.invitationURL(url) else { throw CloudKitStaffSharingError.invalid }
        try await authorize()
        let values = try await container.shareMetadatas(for: [url])
        try await authorize()
        guard values.count == 1, let result = values[url] else { throw CloudKitStaffSharingError.invalid }
        return try result.get()
    }

    private static func acceptOrRecoverInvitation(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                                                   account: CompanyCloudKitAccount, member: BackendAppUserRecord, url: URL,
                                                   authorize: Authorize) async throws {
        let container = try container()
        var value = try await metadata(container: container, url: url, authorize: authorize)
        _ = try CloudKitStaffShareEvidence(metadata: value).verify(plan: plan, workspace: workspace, account: account,
                                                                 member: member, requiresAccepted: false)
        if value.participantStatus == .pending {
            try await authorize()
            let result = try await container.accept([value])
            try await authorize()
            guard result.count == 1, let saved = result[value], try saved.get().recordID == value.share.recordID else {
                throw CloudKitStaffSharingError.invalid
            }
            value = try await metadata(container: container, url: url, authorize: authorize)
        }
        let zone = try CloudKitStaffShareEvidence(metadata: value).verify(plan: plan, workspace: workspace, account: account,
                                                                        member: member, requiresAccepted: false)
        guard value.participantStatus == .accepted else { throw CloudKitStaffSharingError.permission }
        let rootID = CKRecord.ID(recordName: plan.rootRecordName, zoneID: zone)
        try await authorize()
        let records = try await container.sharedCloudDatabase.records(for: [rootID])
        try await authorize()
        guard records.count == 1, let root = records[rootID] else { throw CloudKitStaffSharingError.invalid }
        try CloudKitStaffShareRecords.verifyRoot(try root.get(), plan: plan, zone: zone)
    }

    private static func removeOrRecoverShare(plan: CloudKitStaffSharePlan, workspace: CompanyWorkspaceIdentity,
                                             account: CompanyCloudKitAccount, authorize: Authorize) async throws {
        try plan.validate(workspace: workspace)
        guard account.accountHash == plan.ownerAccountHash, account.environment == plan.environment,
              plan.state == "revoked", plan.cloudKitRevocationRequired else { throw CloudKitStaffSharingError.review }
        let database = try container().privateCloudDatabase
        let (root, share) = try await readOwner(database: database, plan: plan, account: account, authorize: authorize)
        guard let share else { return } // Verified absent, including a lost deletion reply.
        guard let root else { throw CloudKitStaffSharingError.changed }
        _ = try verifyOwnerShare(share, root: root, plan: plan, account: account, enforceParticipant: false)
        try await authorize()
        // Delete only the exact share, not its zone, root or any work records.
        let removed = try await database.modifyRecords(saving: [], deleting: [share.recordID], atomically: true)
        try await authorize()
        guard removed.saveResults.isEmpty, removed.deleteResults.count == 1, let result = removed.deleteResults[share.recordID] else {
            throw CloudKitStaffSharingError.invalid
        }
        try result.get()
        let (_, remaining) = try await readOwner(database: database, plan: plan, account: account, authorize: authorize)
        guard remaining == nil else { throw CloudKitStaffSharingError.review }
    }
}
