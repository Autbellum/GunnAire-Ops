import Foundation
import CloudKit
import Testing
@testable import GunnAire_Ops

@MainActor struct CloudKitStaffSetupTests {
    @MainActor final class Fixture {
        let base = CloudKitStaffSharingTests()
        var stamp: CloudKitStaffSetupStamp?
        var owner: Bool
        var role: String
        var active = true
        var accountSuffix = ""
        var saved: [String: Data] = [:]
        var rows: [CloudKitStaffSharePlan] = []
        var mutations: [(String, Data)] = []
        var operations: Set<String> = []
        var lostReplies = 0
        var writeCount = 0
        var failWrite: Int?
        var appleInvitations: [UUID] = []
        var appleAccepts: [UUID] = []
        var appleCleanups: [UUID] = []
        var appleCreated: Set<UUID> = []
        var failAppleReply = false
        var afterWorkspace: (() -> Void)?
        var beforeApple: (() -> Void)?
        var listOverride: Data?
        var listPages: [Data] = []
        var listCursors: [String?] = []
        var ownerFresh = true
        let invitation = URL(string: "https://www.icloud.com/share/fixture-original-invitation")!
        init(owner: Bool = false, state: String? = nil) throws {
            self.owner = owner; self.role = owner ? "Admin" : "Field Technician"
            stamp = .init(session: .init(backendOrigin: "https://fixture.gunnaire.invalid", email: owner ? "owner@gunnaire.com" : base.member.email,
                                        tokenFingerprint: String(repeating: "1", count: 64), expiresAt: base.now.addingTimeInterval(3600)), accountGeneration: UUID())
            if let state { rows = [try plan(state)] }
        }
        var account: CompanyCloudKitAccount {
            let name = (owner ? base.ownerName : base.participantName) + accountSuffix
            return .init(environment: "development", accountHash: CloudKitStaffSharePlan.accountHash(recordName: name, environment: "development"), recordName: name)
        }
        func plan(_ state: String, id: UUID? = nil, revision: Int? = nil, cleanup: Bool = false,
                  changes: [String: Any] = [:]) throws -> CloudKitStaffSharePlan {
            let fields: [String: Any] = ["id": (id ?? base.shareID).uuidString.lowercased(), "state": state,
                "revision": revision ?? ["requested": 1, "approved": 2, "invited": 3, "accepted": 4, "revoked": 5][state]!,
                "businessAccessEligible": state == "accepted", "cloudKitRevocationRequired": cleanup, "participantIdentityAvailable": true]
            return try base.plan(fields.merging(changes) { _, new in new })
        }
        func bytes(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
        func request(_ path: String, _ method: String, _ body: Data?) throws -> Data {
            if path == "/api/workspace" {
                let value = try bytes(["user": ["email": stamp?.session.email ?? "signed-out@gunnaire.com", "role": role, "isActive": active],
                    "workspace": JSONSerialization.jsonObject(with: JSONEncoder().encode(base.workspace))])
                let callback = afterWorkspace; afterWorkspace = nil; callback?()
                return value
            }
            let parts = URLComponents(string: path)!.path.components(separatedBy: "/")
            if method == "GET" {
                if parts.count == 4 {
                    listCursors.append(URLComponents(string: path)!.queryItems?.first { $0.name == "after" }?.value)
                    if !listPages.isEmpty { return listPages.removeFirst() }
                    if let listOverride { return listOverride }
                    return try bytes(["shares": rows.sorted { $0.id.uuidString < $1.id.uuidString }.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }, "nextCursor": NSNull()])
                }
                let row = rows.first { $0.id.uuidString.lowercased() == parts[4] }!
                if parts.last == "owner-authority", !ownerFresh { throw GunnAireBackendError.server(statusCode: 403, message: "Sign in again") }
                if parts.last == "participant" {
                    return try bytes(["id": row.id.uuidString.lowercased(), "companyID": row.companyID.uuidString.lowercased(),
                        "environment": row.environment, "revision": row.revision, "participantAccountHash": row.participantAccountHash,
                        "recordName": base.participantName])
                }
                return try JSONEncoder().encode(row)
            }
            guard let body else { throw CloudKitStaffSharingError.invalid }
            mutations.append((path, body))
            let fields = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let operation = fields["operationID"] as! String
            let id = parts.count == 4 ? UUID(uuidString: operation)! : UUID(uuidString: parts[4])!
            if operations.insert(operation).inserted {
                if parts.count == 4 { rows.append(try plan("requested", id: id)) }
                else {
                    let index = rows.firstIndex { $0.id == id }!, prior = rows[index], action = parts.last!
                    guard fields["expectedRevision"] as? Int == prior.revision else { throw GunnAireBackendError.server(statusCode: 409, message: "fixture conflict") }
                    let state = ["approve": "approved", "invite": "invited", "accept": "accepted", "revoke": "revoked", "confirm-cleanup": "revoked"][action]!
                    rows[index] = try plan(state, id: id, revision: prior.revision + 1, cleanup: action == "revoke" && prior.state != "requested")
                }
            }
            if lostReplies > 0 { lostReplies -= 1; throw URLError(.networkConnectionLost) }
            return try JSONEncoder().encode(rows.first { $0.id == id }!)
        }
        var dependencies: CloudKitStaffSetupDependencies {
            .init(stamp: { self.stamp }, account: { self.account }, request: { try self.request($0, $1, $2) },
                  store: .init(read: { self.saved[$0] }, write: {
                      self.writeCount += 1
                      if self.failWrite == self.writeCount { throw CloudKitStaffSharingError.storage }
                      self.saved[$0] = $1
                  }), remote: .init(invitation: { plan, _, _, _, authorize in
                      try await authorize(); self.beforeApple?(); try await authorize()
                      self.appleInvitations.append(plan.id); self.appleCreated.insert(plan.id)
                      if self.failAppleReply { self.failAppleReply = false; throw URLError(.networkConnectionLost) }
                      return self.invitation
                  }, accept: { plan, _, _, _, _, authorize in
                      try await authorize(); self.beforeApple?(); try await authorize(); self.appleAccepts.append(plan.id)
                  }, cleanup: { plan, _, _, authorize in
                      try await authorize(); self.beforeApple?(); try await authorize(); self.appleCleanups.append(plan.id)
                  }), now: { self.base.now })
        }
        func model() async -> CloudKitStaffSetupController {
            let model = CloudKitStaffSetupController(dependencies: dependencies); await model.refresh(); return model
        }
    }

    @Test func setupTransportIsAnIdentityOnlyExceptionNotAnOperationalBypass() {
        let company = UUID(), id = UUID()
        for method in ["GET", "POST"] {
            #expect(!CloudKitStaffSetupPolicy.allows(path: "/api/invoices", method: method, bytes: method == "POST" ? 5 : nil))
        }
        #expect(CloudKitStaffSetupPolicy.allows(path: "/api/workspace", method: "GET", bytes: nil))
        for suffix in [nil, id] {
            let path = CloudKitStaffSetupPolicy.query(company: company, environment: "development", id: suffix)
            #expect(CloudKitStaffSetupPolicy.allows(path: path, method: "GET", bytes: nil))
            #expect(!CloudKitStaffSetupPolicy.allows(path: path + "&environment=production", method: "GET", bytes: nil))
            #expect(!CloudKitStaffSetupPolicy.allows(path: "https://attacker.invalid" + path, method: "GET", bytes: nil))
        }
        for path in ["/api/workspace/bind", "/api/workspace/staff-shares/../bind", "/api/workspace/staff-shares/%2e%2e/bind", "/api/workspace/staff-shares/", "/api/workspace/staff-shares#fragment"] {
            #expect(!CloudKitStaffSetupPolicy.allows(path: path, method: "POST", bytes: 20))
        }
        #expect(CompanyWorkspaceRequestPolicy.needsWorkspaceProof(path: "/api/workspace/staff-shares"))
        #expect(!CloudKitStaffSetupPolicy.allows(path: CloudKitStaffSetupPolicy.base, method: "POST", bytes: 8193))
    }

    @Test func enrollmentRequiresExplicitConsentAndPersistsBeforeSending() async throws {
        let fixture = try Fixture(), model = await fixture.model()
        #expect(model.error == nil); #expect(model.canEnroll)
        await model.enroll(confirmed: false); #expect(fixture.mutations.isEmpty); #expect(fixture.saved.isEmpty)
        await model.enroll(confirmed: true)
        #expect(fixture.mutations.count == 1); #expect(fixture.writeCount == 2)
        #expect(model.plans.count == 1); #expect(model.plans.first?.state == "requested"); #expect(!model.canEnroll)
        let body = try JSONSerialization.jsonObject(with: fixture.mutations[0].1) as! [String: String]
        #expect(body["participantRecordName"] == fixture.base.participantName)
        #expect(body["operationID"] == model.plans.first?.id.uuidString.lowercased())
        #expect(!model.needsRecovery)
    }

    @Test func lostEnrollmentReplyRelaunchRecoversSameOperationWithoutReplacement() async throws {
        let fixture = try Fixture(), model = await fixture.model(); fixture.lostReplies = 1
        await model.enroll(confirmed: true)
        #expect(model.needsRecovery); #expect(fixture.rows.count == 1)
        let relaunched = await fixture.model()
        #expect(relaunched.needsRecovery); #expect(!relaunched.canEnroll)
        await relaunched.enroll(confirmed: true); #expect(fixture.mutations.count == 1)
        await relaunched.recover()
        #expect(fixture.mutations.count == 2); #expect(fixture.mutations[0].1 == fixture.mutations[1].1)
        #expect(fixture.rows.count == 1); #expect(!relaunched.needsRecovery)
    }

    @Test func storageFailureBeforeRequestHasNoNetworkMutationAndAfterReplyKeepsOriginal() async throws {
        for failedWrite in [1, 2] {
            let fixture = try Fixture(), model = await fixture.model(); fixture.failWrite = failedWrite
            await model.enroll(confirmed: true)
            #expect(model.error == .storage)
            #expect(fixture.mutations.count == failedWrite - 1)
            fixture.failWrite = nil
            let relaunched = await fixture.model()
            if failedWrite == 2 {
                #expect(relaunched.needsRecovery); await relaunched.recover(); #expect(fixture.rows.count == 1)
                #expect(fixture.mutations[0].1 == fixture.mutations[1].1)
            } else { #expect(relaunched.canEnroll) }
        }
    }

    @Test func ownerCannotEnrollAndStaffCannotApproveOrCreateOwnerInvitation() async throws {
        let owner = try Fixture(owner: true), ownerModel = await owner.model()
        await ownerModel.enroll(confirmed: true); #expect(owner.mutations.isEmpty)
        for role in ["Field Technician", "Dispatcher", "Accounting", "Standard", "Admin"] {
            let fixture = try Fixture(state: "requested"); fixture.role = role
            let model = await fixture.model(); await model.approve(fixture.base.shareID, confirmed: true)
            #expect(fixture.mutations.isEmpty)
            fixture.rows = [try fixture.plan("approved")]; await model.refresh()
            await model.invite(fixture.base.shareID, confirmed: true)
            #expect(fixture.appleInvitations.isEmpty)
        }
    }

    @Test func accountSessionAndRoleChangesStopActionsBeforeAppleAndServerMutations() async throws {
        for kind in ["account", "session", "role", "inactive"] {
            let fixture = try Fixture(owner: true, state: "approved"), model = await fixture.model()
            switch kind {
            case "account": fixture.accountSuffix = "-changed"
            case "session": fixture.stamp = nil
            case "role": fixture.role = "Dispatcher"
            default: fixture.active = false
            }
            await model.invite(fixture.base.shareID, confirmed: true)
            #expect(fixture.appleInvitations.isEmpty); #expect(fixture.mutations.isEmpty)
            #expect(model.error != nil)
        }
    }

    @Test func accountChangeDuringAwaitCannotExposeAStaleWorkspaceOrCreateAShare() async throws {
        let fixture = try Fixture(owner: true, state: "approved")
        fixture.afterWorkspace = { fixture.stamp = nil }
        let model = await fixture.model()
        #expect(model.context == nil); #expect(model.plans.isEmpty); #expect(model.error == .changed)
        let next = try Fixture(owner: true, state: "approved"), nextModel = await next.model()
        next.beforeApple = { next.accountSuffix = "-changed" }
        await nextModel.invite(next.base.shareID, confirmed: true)
        #expect(next.appleInvitations.isEmpty); #expect(next.mutations.isEmpty); #expect(nextModel.needsRecovery)
    }

    @Test func privateInvitationRecordsOriginalURLAndRecoversLostAppleReply() async throws {
        let fixture = try Fixture(owner: true, state: "approved"), model = await fixture.model(); fixture.failAppleReply = true
        await model.invite(fixture.base.shareID, confirmed: true)
        #expect(model.needsRecovery); #expect(fixture.mutations.isEmpty); #expect(fixture.appleCreated.count == 1)
        let relaunched = await fixture.model(); await relaunched.recover()
        #expect(!relaunched.needsRecovery); #expect(relaunched.plans.first?.state == "invited")
        #expect(fixture.appleCreated == [fixture.base.shareID])
        #expect(fixture.appleInvitations == [fixture.base.shareID, fixture.base.shareID])
        #expect(relaunched.journal?.invitationURLs[fixture.base.shareID.uuidString.lowercased()] == fixture.invitation)
    }

    @Test func lostBackendInvitationReplyDoesNotRepeatAppleWork() async throws {
        let fixture = try Fixture(owner: true, state: "approved"), model = await fixture.model(); fixture.lostReplies = 1
        await model.invite(fixture.base.shareID, confirmed: true)
        #expect(model.needsRecovery); #expect(fixture.appleInvitations.count == 1)
        let relaunched = await fixture.model(); await relaunched.recover()
        #expect(fixture.appleInvitations.count == 1); #expect(fixture.mutations[0].1 == fixture.mutations[1].1)
        #expect(relaunched.plans.first?.state == "invited"); #expect(!relaunched.needsRecovery)
    }

    @Test func acceptedInvitationStillDoesNotAuthorizeThePrivateOperationalStore() async throws {
        let fixture = try Fixture(state: "invited"), model = await fixture.model()
        await model.accept(fixture.base.shareID, url: fixture.invitation, confirmed: true)
        #expect(fixture.appleAccepts == [fixture.base.shareID]); #expect(model.plans.first?.state == "accepted")
        #expect(model.plans.first?.localCloudKitProofRequired == true)
        #expect(fixture.account.accountHash != fixture.base.workspace.binding(for: "development")?.cloudAccountHash)
    }

    @Test func revocationAndCloudKitCleanupAreExplicitSeparateActionsWithOriginalRecovery() async throws {
        let fixture = try Fixture(owner: true, state: "accepted"), model = await fixture.model()
        await model.revoke(fixture.base.shareID, confirmed: true)
        #expect(fixture.appleCleanups.isEmpty); #expect(model.plans.first?.cloudKitRevocationRequired == true)
        fixture.lostReplies = 1
        await model.cleanup(fixture.base.shareID, confirmed: true)
        #expect(fixture.appleCleanups == [fixture.base.shareID]); #expect(model.needsRecovery)
        let relaunched = await fixture.model(); await relaunched.recover()
        #expect(fixture.appleCleanups == [fixture.base.shareID]); #expect(!relaunched.needsRecovery)
        #expect(relaunched.plans.first?.state == "revoked"); #expect(relaunched.plans.first?.cloudKitRevocationRequired == false)
        #expect(fixture.mutations[1].1 == fixture.mutations[2].1)
    }

    @Test func selfRevocationCannotPerformOwnerAppleCleanup() async throws {
        let fixture = try Fixture(state: "accepted"), model = await fixture.model()
        await model.revoke(fixture.base.shareID, confirmed: true)
        #expect(model.plans.first?.state == "revoked")
        await model.cleanup(fixture.base.shareID, confirmed: true)
        #expect(fixture.appleCleanups.isEmpty); #expect(fixture.mutations.count == 1)
    }

    @Test func revokedOriginalRecoveryNeverCreatesOrAcceptsAnotherShare() async throws {
        let fixture = try Fixture(owner: true, state: "approved"), model = await fixture.model(); fixture.failAppleReply = true
        await model.invite(fixture.base.shareID, confirmed: true)
        fixture.rows = [try fixture.plan("revoked", cleanup: true)]
        let relaunched = await fixture.model(); await relaunched.recover()
        #expect(!relaunched.needsRecovery); #expect(fixture.appleInvitations.count == 1); #expect(fixture.mutations.isEmpty)
        #expect(relaunched.plans.first?.cloudKitRevocationRequired == true)
    }

    @Test func malformedDuplicateForeignAndIncompleteListsNeverOfferNewEnrollment() async throws {
        for kind in ["malformed", "duplicate", "foreign", "cursor"] {
            let fixture = try Fixture(state: "requested")
            let row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.rows[0]))
            switch kind {
            case "malformed": fixture.listOverride = Data("{}".utf8)
            case "duplicate": fixture.listOverride = try fixture.bytes(["shares": [row, row], "nextCursor": NSNull()])
            case "foreign": fixture.rows = [try fixture.plan("requested", changes: ["memberEmail": "different@gunnaire.com"])]
            default: fixture.listOverride = try fixture.bytes(["shares": [row], "nextCursor": fixture.rows[0].id.uuidString.lowercased()])
            }
            let model = await fixture.model()
            #expect(model.error != nil); #expect(model.context == nil); #expect(!model.canEnroll)
        }
    }

    @Test func changedOriginalPlanAndCorruptScopedJournalRemainRetained() async throws {
        for kind in ["bytes", "scope", "plan"] {
            let fixture = try Fixture(), model = await fixture.model(); fixture.lostReplies = 1
            await model.enroll(confirmed: true)
            let key = try #require(fixture.saved.keys.first)
            if kind == "bytes" { fixture.saved[key] = Data("broken".utf8) }
            else if kind == "scope" {
                var object = try JSONSerialization.jsonObject(with: fixture.saved[key]!) as! [String: Any]
                var scope = object["scope"] as! [String: Any]; scope["email"] = "different@gunnaire.com"; object["scope"] = scope
                fixture.saved[key] = try fixture.bytes(object)
            } else {
                await model.recover()
                fixture.rows = [try fixture.plan("requested", id: fixture.rows[0].id,
                    changes: ["zoneName": "ga-staff-a1000000-0000-4000-8000-000000000099"])]
            }
            let retained = fixture.saved[key]
            let relaunched = await fixture.model()
            #expect(relaunched.error != nil); #expect(!relaunched.canEnroll); #expect(fixture.saved[key] == retained)
        }
    }

    @Test func ownerReauthenticationDeadlineIsCheckedAgainImmediatelyBeforeAppleWork() async throws {
        for state in ["approved", "revoked"] {
            let fixture = try Fixture(owner: true, state: state)
            if state == "revoked" { fixture.rows = [try fixture.plan("revoked", cleanup: true)] }
            let model = await fixture.model(); fixture.beforeApple = { fixture.ownerFresh = false }
            if state == "approved" { await model.invite(fixture.base.shareID, confirmed: true) }
            else { await model.cleanup(fixture.base.shareID, confirmed: true) }
            #expect(fixture.appleInvitations.isEmpty); #expect(fixture.appleCleanups.isEmpty); #expect(fixture.mutations.isEmpty)
            #expect(model.error == .access); #expect(model.needsRecovery)
        }
    }

    @Test func completePaginationRetainsOriginalCursorAndEveryHistoricalRequest() async throws {
        let fixture = try Fixture()
        let rows = try (0..<61).map { _ -> CloudKitStaffSharePlan in
            let id = UUID()
            return try fixture.plan("revoked", id: id, changes: ["zoneName": "ga-staff-" + id.uuidString.lowercased()])
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let objects = try rows.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }
        fixture.listPages = [try fixture.bytes(["shares": Array(objects.prefix(50)), "nextCursor": rows[49].id.uuidString.lowercased()]),
                             try fixture.bytes(["shares": Array(objects.dropFirst(50)), "nextCursor": NSNull()])]
        let model = await fixture.model()
        #expect(model.error == nil); #expect(model.plans.count == 61); #expect(model.canEnroll)
        #expect(fixture.listCursors == [nil, rows[49].id.uuidString.lowercased()])
    }

    @Test func concurrentWindowCannotReplaceTheOriginalInFlightSetup() async throws {
        let fixture = try Fixture(), model = await fixture.model()
        let scope = try #require(model.context?.scope.key)
        try CloudKitStaffSetupLocks.acquire(scope)
        defer { CloudKitStaffSetupLocks.release(scope) }
        await model.enroll(confirmed: true)
        #expect(model.error == .review); #expect(fixture.mutations.isEmpty); #expect(fixture.saved.isEmpty)
    }

    @Test func alteredPendingBodyCannotReplayOrBeSilentlyDiscarded() async throws {
        let fixture = try Fixture(), model = await fixture.model(); fixture.lostReplies = 1
        await model.enroll(confirmed: true)
        let key = try #require(fixture.saved.keys.first)
        var saved = try JSONDecoder().decode(CloudKitStaffSetupJournal.self, from: fixture.saved[key]!)
        let original = try #require(saved.pending)
        var body = try JSONSerialization.jsonObject(with: original.body) as! [String: Any]
        body["confirmPrivateReadOnlyCloudKitShare"] = true
        saved.pending = .init(operationID: original.operationID, shareID: original.shareID, action: original.action, body: try fixture.bytes(body))
        fixture.saved[key] = try JSONEncoder().encode(saved)
        let retained = fixture.saved[key], relaunched = await fixture.model()
        await relaunched.recover()
        #expect(relaunched.error == .storage); #expect(fixture.mutations.count == 1); #expect(fixture.saved[key] == retained)
    }

    @Test func encryptedJournalRejectsWrongKeyAndScopesWithoutDiscardingBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StaffSetupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var key = Data(repeating: 7, count: 32)
        let store = SharedTimeLocalStore.encrypted(directory: directory, key: { _ in key })
        let secret = Data("original-private-invitation".utf8)
        try store.write("one-company-staff-scope", secret)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let sealed = try Data(contentsOf: file)
        #expect(sealed.range(of: secret) == nil); #expect(try store.read("one-company-staff-scope") == secret)
        #expect(try store.read("different-scope") == nil)
        key = Data(repeating: 8, count: 32)
        #expect(throws: SharedTimeError.self) { try store.read("one-company-staff-scope") }
        #expect(try Data(contentsOf: file) == sealed)
    }

    @Test func invitationsRequireExactAppleRoutingAndCannotReplaceAnUnopenedOriginal() throws {
        let base = CloudKitStaffSharingTests(), plan = try base.plan()
        let first = CloudKitStaffInvitation(id: UUID(), url: URL(string: "https://www.icloud.com/share/original")!, containerID: plan.containerID,
                                           zoneName: plan.zoneName, shareName: plan.shareRecordName, rootName: plan.rootRecordName)
        var stored: CloudKitStaffInvitation?
        let inbox = CloudKitStaffInvitationInbox(read: { stored }, write: { stored = $0 })
        #expect(first.matches(plan)); inbox.receive(first); #expect(stored == first)
        let different = CloudKitStaffInvitation(id: UUID(), url: URL(string: "https://www.icloud.com/share/different")!, containerID: plan.containerID,
                                               zoneName: plan.zoneName, shareName: plan.shareRecordName, rootName: plan.rootRecordName)
        inbox.receive(different); #expect(inbox.error == .review); #expect(stored == first)
        let relaunched = CloudKitStaffInvitationInbox(read: { stored }, write: { stored = $0 })
        #expect(relaunched.pending == first)
        relaunched.dismissOriginal(UUID()); #expect(stored == first)
        relaunched.dismissOriginal(first.id); #expect(stored == nil)
        for text in ["http://icloud.com/share/original", "https://icloud.com.attacker.invalid/share/original", "https://user@icloud.com/share/original", "https://icloud.com:444/share/original", "https://icloud.com/share/"] {
            #expect(!CloudKitStaffSetupPolicy.invitationURL(URL(string: text)!))
        }
    }
}
