import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffReplicaAutomaticDeliveryTests {
    @MainActor final class Fixture {
        let cloud: StaffReplicaDeliveryTests.Fixture
        let source: StaffReplicaSourceContext
        var plans: [CloudKitStaffSharePlan]
        var saved: [String: Data] = [:]
        var posts: [Data] = []
        var writes = 0
        var failWrite: Int?
        var loseWriteReply: Int?
        var losePreparationReply = false
        var allowed = true
        var afterPrepare: (() -> Void)?
        var reject = false
        var rejectPath: String?
        var responseChanges: [String: Any] = [:]
        init() throws {
            cloud = try .init(); plans = [try cloud.base.plan()]
            let context = try cloud.context()
            source = .init(scope: .init(backendOrigin: context.stamp.session.backendOrigin, actorEmail: context.member.email,
                binding: context.workspace.binding(for: "development")!, storeUUID: UUID().uuidString),
                stamp: .init(generation: UUID(), session: context.stamp.session))
        }
        func cleanup() { cloud.cleanup() }
        func journal() throws -> StaffReplicaAutomaticJournal? {
            try saved[coordinator().key(source, cloud.base.plan())].map { try JSONDecoder().decode(StaffReplicaAutomaticJournal.self, from: $0) }
        }
        func coordinator() -> StaffReplicaAutomaticDelivery {
            .init(dependencies: .init(setup: { (try self.cloud.context(), self.plans) }, check: { source in
                guard self.allowed, source.scope == self.source.scope, source.stamp == self.source.stamp else { throw StaffReplicaDeliveryError.access }
            }, prepare: { path, bytes in
                let request = try JSONDecoder().decode(StaffReplicaPreparation.self, from: bytes)
                let id = UUID(uuidString: request.operationID)!
                let key = self.coordinator().key(self.source, self.plans.first { StaffReplicaPreparationPolicy.path($0) == path }!)
                let journal = try JSONDecoder().decode(StaffReplicaAutomaticJournal.self, from: #require(self.saved[key]))
                #expect(journal.pending?.request == request) // Durable before the actual request.
                self.posts.append(bytes)
                if path == self.rejectPath { throw StaffReplicaDeliveryError.unavailable }
                if self.reject { self.reject = false; throw StaffReplicaPreparationRejected() }
                if self.cloud.originals[id] == nil {
                    guard request.expectedSequence == self.cloud.sequence else { throw StaffReplicaPreparationRejected() }
                    self.cloud.originals[id] = try self.cloud.payload(operation: id, sequence: request.expectedSequence,
                                                                      authorization: self.cloud.authorizationSequence)
                }
                let data = try self.cloud.receipt(self.cloud.originals[id]!, changes: self.responseChanges)
                self.afterPrepare?(); self.afterPrepare = nil
                if self.losePreparationReply { self.losePreparationReply = false; throw StaffReplicaDeliveryError.unavailable }
                return data
            }, delivery: cloud.coordinator(), store: .init(read: { self.saved[$0] }, write: { key, bytes in
                self.writes += 1
                if self.writes == self.failWrite { throw StaffReplicaDeliveryError.storage }
                self.saved[key] = bytes
                if self.writes == self.loseWriteReply { throw StaffReplicaDeliveryError.storage }
            }), now: { self.cloud.base.now }))
        }
        func run() async throws -> StaffReplicaAutomaticSummary { try await coordinator().deliver(source: source, sequence: cloud.sequence) }
        func changedPlan(_ changes: [String: Any]) throws -> CloudKitStaffSharePlan {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cloud.base.plan())) as! [String: Any]
            object.merge(changes) { _, new in new }
            return try JSONDecoder().decode(CloudKitStaffSharePlan.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func completePipelinePreparesSealsUploadsAndVerifiesWithoutRepeating() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = try await f.run()
        #expect(first.shared == 1 && first.needsAttention == 0)
        #expect(f.posts.count == 1 && f.cloud.saves == 1 && f.cloud.remote.count == 2)
        #expect(try f.journal()?.pending == nil && f.journal()?.lastShared != nil)
        let again = try await f.run()
        #expect(again.shared == 1 && f.posts.count == 1 && f.cloud.saves == 1)
        #expect(again.message.contains("receipt is not yet confirmed"))
        for data in f.saved.values {
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("keyBase64") && !text.contains("sealedBase64") && !text.contains("Original work"))
        }
    }
    @Test func lostPreparationRecoversExactOriginalAfterRelaunch() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.losePreparationReply = true
        #expect(try await f.run().needsAttention == 1)
        #expect(f.posts.count == 1 && f.cloud.saves == 0)
        #expect(try f.journal()?.pending != nil)
        #expect(try await f.run().shared == 1)
        #expect(f.posts.count == 2 && f.posts[0] == f.posts[1] && f.cloud.originals.count == 1 && f.cloud.saves == 1)
    }
    @Test func lostCloudReplyVerifiesOriginalInsteadOfSavingTwice() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.cloud.loseSaveReply = true
        #expect(try await f.run().shared == 1)
        #expect(f.cloud.saves == 1 && f.posts.count == 1)
        #expect(try await f.run().shared == 1)
        #expect(f.cloud.saves == 1 && f.posts.count == 1)
    }
    @Test func secondOwnerDeviceAdoptsActualEncryptedAssetWithoutPreparingOrOverwriting() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = try await f.cloud.publish()
        #expect(try await f.run().shared == 1)
        #expect(f.posts.isEmpty && f.cloud.saves == 1)
        #expect(try f.journal()?.lastShared == original)
    }
    @Test func matchingHeadWithoutOriginalAssetCannotClaimSharedOrReplaceIt() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let original = try await f.cloud.publish()
        f.cloud.remote[StaffReplicaCloudRecords.payloadName(original.operationID)] = nil
        #expect(try await f.run().needsAttention == 1)
        #expect(f.posts.isEmpty && f.cloud.saves == 1)
    }
    @Test func corruptPeerAssetCannotClaimShared() async throws {
        let f = try Fixture(); defer { f.cleanup() }; let original = try await f.cloud.publish()
        let key = StaffReplicaCloudRecords.payloadName(original.operationID)
        f.cloud.remote[key] = (original, Data(repeating: 0, count: original.payloadBytes + 28))
        #expect(try await f.run().needsAttention == 1)
        #expect(f.posts.isEmpty && f.cloud.saves == 1)
    }
    @Test func supersededPreparationIsRecoveredBeforeCurrentOperation() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.losePreparationReply = true
        _ = try await f.run(); let first = try #require(f.posts.first)
        f.cloud.sequence = 2
        #expect(try await f.run().shared == 1)
        #expect(f.posts.count == 3 && f.posts[1] == first && f.posts[2] != first)
        #expect(f.cloud.saves == 1)
        #expect(try f.journal()?.lastShared?.sourceSequence == 2)
    }
    @Test func changedSourceAfterPreparationDoesNotUploadStaleData() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.afterPrepare = { f.cloud.sequence = 2 }
        #expect(try await f.run().needsAttention == 1)
        #expect(f.cloud.saves == 0)
        #expect(try await f.run().shared == 1)
        #expect(f.cloud.saves == 1)
        #expect(try f.journal()?.lastShared?.sourceSequence == 2)
    }
    @Test func revokedAuthorityAfterPreparationPreservesOriginalAndMakesNoCloudWrite() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.afterPrepare = { f.cloud.authorized = false }
        #expect(try await f.run().needsAttention == 1)
        #expect(f.cloud.saves == 0 && f.posts.count == 1)
        #expect(try f.journal()?.pending != nil)
    }
    @Test func nestedCloudReadStillChecksPhysicalOwnerStore() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.cloud.afterRead = { f.allowed = false }
        await #expect(throws: StaffReplicaDeliveryError.access) { try await f.run() }
        #expect(f.posts.isEmpty && f.cloud.saves == 0)
    }
    @Test func participantCannotEnterOwnerPreparationPipeline() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.cloud.signIn(owner: false)
        await #expect(throws: StaffReplicaDeliveryError.access) { try await f.run() }
        #expect(f.posts.isEmpty && f.cloud.saves == 0)
    }
    @Test func peerWinningAfterOurPreparationIsAdoptedWithoutASecondCloudWrite() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let peer = try f.cloud.payload(), sealed = try f.cloud.seal(peer)
        f.cloud.originals[peer.manifest.operationID] = peer
        f.afterPrepare = {
            f.cloud.remote[StaffReplicaCloudRecords.headName] = (peer.manifest, nil)
            f.cloud.remote[StaffReplicaCloudRecords.payloadName(peer.manifest.operationID)] = (peer.manifest, sealed.bytes)
        }
        #expect(try await f.run().shared == 1)
        #expect(f.posts.count == 1 && f.cloud.saves == 0)
        #expect(try f.journal()?.lastShared == peer.manifest && f.journal()?.pending == nil)
    }
    @Test func malformedPreparationReceiptRetainsExactPendingWithoutCloudWrite() async throws {
        for changes: [String: Any] in [["operationID": UUID().uuidString], ["keyBase64": "unexpected"], ["operationalWorkspaceReady": true]] {
            let f = try Fixture(); defer { f.cleanup() }; f.responseChanges = changes
            #expect(try await f.run().needsAttention == 1)
            #expect(f.cloud.saves == 0 && f.posts.count == 1)
            #expect(try f.journal()?.pending != nil)
        }
    }
    @Test func sourceScopeChangeAfterAwaitFailsClosed() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.afterPrepare = { f.allowed = false }
        await #expect(throws: StaffReplicaDeliveryError.access) { try await f.run() }
        #expect(f.cloud.saves == 0)
    }
    @Test func storageFailureBeforeRequestAndAfterDeliveryRecoverWithoutDuplicates() async throws {
        for write in 1...5 {
            let f = try Fixture(); defer { f.cleanup() }; f.failWrite = write
            _ = try await f.run()
            if write == 1 { #expect(f.posts.isEmpty && f.cloud.saves == 0) }
            f.failWrite = nil
            #expect(try await f.run().shared == 1)
            #expect(f.cloud.originals.count == 1 && f.cloud.saves == 1)
            #expect(try f.journal()?.pending == nil)
        }
    }
    @Test func rejectedPreparationIsArchivedAndReplacedOnlyOnFreshPass() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.reject = true
        #expect(try await f.run().needsAttention == 1)
        #expect(f.cloud.saves == 0)
        #expect(try f.journal()?.pending == nil)
        #expect(try await f.run().shared == 1)
        #expect(f.posts.count == 2 && f.posts[0] != f.posts[1])
    }
    @Test func lostLocalWriteAcknowledgementsRecoverOriginalIncludingArchiveAndIndex() async throws {
        for write in 1...4 {
            let f = try Fixture(); defer { f.cleanup() }; f.loseWriteReply = write
            _ = try await f.run(); f.loseWriteReply = nil
            #expect(try await f.run().shared == 1)
            #expect(f.cloud.originals.count == 1 && f.cloud.saves == 1)
            #expect(try f.journal()?.pending == nil)
        }
    }
    @Test func changedInvitationCannotReplacePendingRequest() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.losePreparationReply = true
        _ = try await f.run()
        f.plans = [try f.changedPlan(["revision": 5])]
        #expect(try await f.run().needsAttention == 1)
        #expect(f.posts.count == 1 && f.cloud.saves == 0)
    }
    @Test func oneMemberFailureDoesNotPreventAnotherAcceptedMember() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let failed = try f.changedPlan(["id": UUID().uuidString, "zoneName": "ga-staff-" + UUID().uuidString.lowercased()])
        f.plans.insert(failed, at: 0); f.rejectPath = StaffReplicaPreparationPolicy.path(failed)
        let result = try await f.run()
        #expect(result.shared == 1 && result.needsAttention == 1 && f.cloud.saves == 1)
    }
    @Test func ineligibleMembersNeverPrepareOrPublish() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.plans = [try f.changedPlan(["businessAccessEligible": false, "reviewRequired": true])]
        let result = try await f.run()
        #expect(result.shared == 0 && result.waitingForSetup == 1 && f.posts.isEmpty && f.cloud.saves == 0)
    }
    @Test func preparationRouteCannotBypassOwnerGateOrAddFields() throws {
        let f = try Fixture(); defer { f.cleanup() }; let plan = try f.cloud.base.plan()
        let request = StaffReplicaPreparation(plan: plan, sequence: 1), path = StaffReplicaPreparationPolicy.path(plan)
        let bytes = try request.encoded()
        #expect(StaffReplicaPreparationPolicy.allows(path: path, body: bytes))
        #expect(CompanyWorkspaceRequestPolicy.needsWorkspaceProof(path: path))
        #expect(!CloudKitStaffSetupPolicy.allows(path: path, method: "POST", bytes: bytes.count))
        #expect(!StaffReplicaDeliveryPolicy.allows(path: path))
        for invalid in [path + "/", path + "?companyID=" + request.companyID, path + "#x", "https://example.invalid" + path,
                        path.replacingOccurrences(of: "projections", with: "%70rojections")] {
            #expect(!StaffReplicaPreparationPolicy.allows(path: invalid, body: bytes))
        }
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        object["admin"] = true
        #expect(!StaffReplicaPreparationPolicy.allows(path: path, body: try JSONSerialization.data(withJSONObject: object)))
    }
}
