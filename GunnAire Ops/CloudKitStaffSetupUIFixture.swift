import Foundation

/// Isolated native UI transport; never available in Release and never performs
/// CKContainer, HTTP, signing or real-account work. Test IDs scope all state.
@MainActor enum CloudKitStaffSetupUIFixture {
    static var dependencies: CloudKitStaffSetupDependencies? {
        #if DEBUG
        guard GunnAireCloudKit.usesTestDatabase,
              ProcessInfo.processInfo.arguments.contains("-uiTestStaffCloudKitSetup"),
              let text = ProcessInfo.processInfo.environment["GUNNAIRE_STAFF_SETUP_FIXTURE"], let company = UUID(uuidString: text) else { return nil }
        let server = Server(company: company)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return .init(stamp: { server.stamp }, account: { server.account }, request: { try server.request($0, $1, $2) },
            store: .encrypted(directory: root.appendingPathComponent("UITestStaffSetup-" + company.uuidString), key: { _ in Data(repeating: 83, count: 32) }),
            remote: .init(invitation: { plan, _, _, _, authorize in
                try await authorize(); try server.recordApple("invite", plan); return server.url
            }, accept: { plan, _, _, _, _, authorize in
                try await authorize(); try server.recordApple("accept", plan)
            }, cleanup: { plan, _, _, authorize in
                try await authorize(); try server.recordApple("cleanup", plan)
            }))
        #else
        return nil
        #endif
    }
    #if DEBUG
    private final class Server {
        let company: UUID
        let participant = ProcessInfo.processInfo.arguments.contains("-uiTestStaffAsParticipant")
        let time = "2026-09-09T00:00:00Z"
        let ownerName = "_ui-fixture-owner", memberName = "_ui-fixture-member"
        let url = URL(string: "https://www.icloud.com/share/ui-fixture-original")!
        let generation = UUID()
        let expiry = Date().addingTimeInterval(3600)
        var key: String { "UITestStaffServer-" + company.uuidString }
        var email: String { participant ? "staff@example.invalid" : "owner@example.invalid" }
        var account: CompanyCloudKitAccount {
            let name = participant ? memberName : ownerName
            return .init(environment: "development", accountHash: hash(name), recordName: name)
        }
        var stamp: CloudKitStaffSetupStamp {
            .init(session: .init(backendOrigin: "https://staff-fixture.invalid", email: email, tokenFingerprint: String(repeating: "1", count: 64),
                                 expiresAt: expiry), accountGeneration: generation)
        }
        init(company: UUID) { self.company = company }
        func hash(_ name: String) -> String { CloudKitStaffSharePlan.accountHash(recordName: name, environment: "development") }
        func object(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func row(id: String, state: String, revision: Int, cleanup: Bool = false) -> [String: Any] {
            ["protocolVersion": 1, "id": id, "companyID": company.uuidString.lowercased(), "containerID": GunnAireCloudKit.containerIdentifier,
             "environment": "development", "replicaID": company.uuidString.lowercased(), "ownerAccountHash": hash(ownerName),
             "participantAccountHash": hash(memberName), "memberEmail": "staff@example.invalid", "memberRole": "Field Technician",
             "memberRevision": String(repeating: "a", count: 64), "projectionPolicy": "field-assigned-jobs-v1",
             "zoneName": "ga-staff-" + id, "rootRecordName": "workspace", "shareRecordName": "share-" + id,
             "state": state, "revision": revision, "createdAt": time, "updatedAt": time, "businessAccessEligible": state == "accepted",
             "localCloudKitProofRequired": true, "reviewRequired": false, "cloudKitRevocationRequired": cleanup, "participantIdentityAvailable": true]
        }
        func load() throws -> [String: Any] {
            if let bytes = UserDefaults.standard.data(forKey: key) { return try JSONSerialization.jsonObject(with: bytes) as! [String: Any] }
            if participant && StaffReplicaReceiveUIFixture.isEnabled {
                return ["row": row(id: company.uuidString.lowercased(), state: "invited", revision: 3)]
            }
            return participant ? [:] : ["row": row(id: company.uuidString.lowercased(), state: "requested", revision: 1)]
        }
        func recordApple(_ action: String, _ plan: CloudKitStaffSharePlan) throws {
            var state = try load()
            let slot = "apple-" + action
            guard state[slot] == nil || state[slot] as? String == plan.id.uuidString.lowercased() else { throw CloudKitStaffSharingError.changed }
            state[slot] = plan.id.uuidString.lowercased()
            UserDefaults.standard.set(try object(state), forKey: key)
        }
        func request(_ path: String, _ method: String, _ body: Data?) throws -> Data {
            if path == "/api/workspace" {
                return try object(["user": ["email": email, "role": participant ? "Field Technician" : "Admin", "isActive": true],
                    "workspace": ["companyID": company.uuidString.lowercased(), "containerID": GunnAireCloudKit.containerIdentifier,
                        "bindings": [["companyID": company.uuidString.lowercased(), "containerID": GunnAireCloudKit.containerIdentifier,
                            "environment": "development", "replicaID": company.uuidString.lowercased(), "cloudAccountHash": hash(ownerName), "approvedAt": time]]]])
            }
            var state = try load(), saved = state["row"] as? [String: Any]
            let parts = URLComponents(string: path)!.path.components(separatedBy: "/")
            if method == "GET" {
                if parts.count == 4 { return try object(["shares": saved.map { [$0] } ?? [], "nextCursor": NSNull()]) }
                guard let saved, saved["id"] as? String == parts[4] else { throw CloudKitStaffSharingError.invalid }
                if parts.last == "participant" {
                    return try object(["id": saved["id"]!, "companyID": company.uuidString.lowercased(), "environment": "development",
                        "revision": saved["revision"]!, "participantAccountHash": hash(memberName), "recordName": memberName])
                }
                return try object(saved)
            }
            let input = try JSONSerialization.jsonObject(with: body!) as! [String: Any], operation = input["operationID"] as! String
            var operations = state["operations"] as? [String] ?? []
            if !operations.contains(operation) {
                if parts.count == 4 {
                    guard saved == nil else { throw CloudKitStaffSharingError.review }
                    saved = row(id: operation, state: "requested", revision: 1)
                } else {
                    guard let prior = saved, input["expectedRevision"] as? Int == prior["revision"] as? Int else { throw CloudKitStaffSharingError.review }
                    let action = parts.last!, next = ["approve": "approved", "invite": "invited", "accept": "accepted", "revoke": "revoked", "confirm-cleanup": "revoked"][action]!
                    if action == "invite" || action == "accept" || action == "confirm-cleanup" {
                        let apple = "apple-" + (action == "confirm-cleanup" ? "cleanup" : action)
                        guard state[apple] as? String == prior["id"] as? String else { throw CloudKitStaffSharingError.permission }
                    }
                    saved = row(id: prior["id"] as! String, state: next, revision: (prior["revision"] as! Int) + 1,
                                cleanup: action == "revoke" && prior["state"] as? String != "requested")
                }
                operations.append(operation); state["operations"] = operations; state["row"] = saved
                UserDefaults.standard.set(try object(state), forKey: key)
                if participant && ProcessInfo.processInfo.arguments.contains("-uiTestStaffLostReply") {
                    throw URLError(.networkConnectionLost)
                }
            }
            guard let saved else { throw CloudKitStaffSharingError.invalid }; return try object(saved)
        }
    }
    #endif
}
