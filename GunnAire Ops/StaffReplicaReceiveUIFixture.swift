import Foundation

/// UI-only receipt simulator. No Apple account, shared database, provider data,
/// operational store or production transport is used by this fixture.
@MainActor enum StaffReplicaReceiveUIFixture {
    static var isEnabled: Bool {
        #if DEBUG
        GunnAireCloudKit.usesTestDatabase && ProcessInfo.processInfo.arguments.contains("-uiTestStaffReceipt") &&
        ProcessInfo.processInfo.arguments.contains("-uiTestStaffAsParticipant") &&
        UUID(uuidString: ProcessInfo.processInfo.environment["GUNNAIRE_STAFF_SETUP_FIXTURE"] ?? "") != nil
        #else
        false
        #endif
    }
    static var dependencies: StaffReplicaReceiveDependencies? {
        #if DEBUG
        guard isEnabled, let company = UUID(uuidString: ProcessInfo.processInfo.environment["GUNNAIRE_STAFF_SETUP_FIXTURE"] ?? "") else { return nil }
        return .init(check: { context in
            guard context.workspace.companyID == company, context.member.email == "staff@example.invalid",
                  context.member.role == AppUserRole.fieldTechnician.rawValue, context.stamp.session.backendOrigin == "https://staff-fixture.invalid" else {
                throw StaffReplicaDeliveryError.access
            }
        }, download: { plan, _, url in
            guard plan.companyID == company, plan.state == "accepted", url.absoluteString == "https://www.icloud.com/share/ui-fixture-original" else {
                throw StaffReplicaDeliveryError.invalid
            }
            let key = "UITestStaffReceiptRead-" + company.uuidString
            if ProcessInfo.processInfo.arguments.contains("-uiTestStaffReceiptReadFailure"), !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                throw StaffReplicaDeliveryError.unavailable
            }
            return .init(protocolVersion: 1, schema: StaffReplicaCoreSource.schemaVersion, coverage: StaffReplicaCoreSource.recordKinds,
                operationID: company, membershipID: plan.id, companyID: plan.companyID, environment: plan.environment,
                replicaID: plan.replicaID, memberRevision: plan.memberRevision, projectionPolicy: plan.projectionPolicy,
                sourceSequence: 1, authorizationSequence: 1, payloadSHA256: String(repeating: "b", count: 64),
                payloadBytes: 1024, recordCount: 6, createdAt: plan.updatedAt)
        })
        #else
        return nil
        #endif
    }
}
