import Foundation

/// A complete workspace/identity pair. Callers validate against their own
/// current context, received selection and independently obtained device ID.
struct StaffWorkspaceOperationalSession {
    let hosted: StaffWorkspaceOperationalHostedStore
    let identity: StaffWorkspaceOperationalIdentityJournal

    func validate(plan: CloudKitStaffSharePlan, context: CloudKitStaffSetupController.Context,
                  selectionID: String, deviceFingerprint: String) throws {
        let journal = hosted.journal, imported = hosted.plan
        guard CloudKitStaffSetupPolicy.canonicalID(selectionID),
              journal.scope == context.scope, journal.planID == plan.id,
              journal.selectionID == selectionID,
              imported.companyID == plan.companyID.uuidString.lowercased(),
              imported.environment == plan.environment,
              imported.replicaID == plan.replicaID.uuidString.lowercased(),
              imported.memberRole == plan.memberRole,
              imported.selectionID == journal.selectionID,
              imported.sourceSequence == journal.sourceSequence,
              imported.contentSHA256 == journal.contentSHA256,
              imported.recordCount == journal.recordCount else { throw StaffReplicaDeliveryError.changed }
        try StaffWorkspaceOperationalPresentation.requireBound(hosted: hosted, identity: identity,
            account: context.account, deviceFingerprint: deviceFingerprint)
    }
}

/// Published atomically; a view can never combine a new host with old identity
/// fields. Scope identity is separate from content identity for navigation.
struct StaffReplicaPresentation {
    let workspace: StaffWorkspaceOperationalSession
    let context: CloudKitStaffSetupController.Context
    let plan: CloudKitStaffSharePlan
    let deviceFingerprint: String

    var navigationScope: String {
        CompanyWorkspaceSession.digest([context.scope.key, plan.id.uuidString.lowercased(),
            plan.memberRevision, plan.memberRole, deviceFingerprint].joined(separator: "\n"))
    }
    var viewIdentity: String {
        CompanyWorkspaceSession.digest([navigationScope, workspace.hosted.journal.selectionID,
            workspace.hosted.journal.contentSHA256, String(workspace.hosted.journal.sourceSequence)].joined(separator: "\n"))
    }
}
