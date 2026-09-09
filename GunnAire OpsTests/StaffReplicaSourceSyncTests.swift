import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffReplicaSourceSyncTests {
    @MainActor final class Fixture {
        let binding = CompanyCloudKitBinding(companyID: UUID(), containerID: GunnAireCloudKit.containerIdentifier,
            environment: "development", replicaID: UUID(), cloudAccountHash: String(repeating: "a", count: 64), approvedAt: "2026-09-09T00:00:00Z")
        var storeID = UUID().uuidString
        var generation = UUID()
        var authorized = true
        var saved: [String: Data] = [:]
        var writes = 0
        var failWrite: Int?
        var sequence = 0
        var remote: [StaffReplicaSourceRemoteRecord] = []
        var local: [StaffReplicaCoreRecord] = []
        var deleted = Set<String>()
        var posts: [Data] = []
        var operations: [String: Data] = [:]
        var reads = 0
        var captures = 0
        var loseReply = false
        var afterRequest: (() -> Void)?
        var beforePost: (() -> Void)?
        var pageMutation: ((StaffReplicaSourcePage) -> StaffReplicaSourcePage)?
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        var scope: StaffReplicaSourceScope {
            .init(backendOrigin: "https://fixture.example.invalid", actorEmail: "owner@example.invalid", binding: binding, storeUUID: storeID)
        }
        var context: StaffReplicaSourceContext {
            .init(scope: scope, stamp: .init(generation: generation, session: .init(backendOrigin: scope.backendOrigin,
                email: scope.actorEmail, tokenFingerprint: String(repeating: "b", count: 64), expiresAt: now.addingTimeInterval(3600))))
        }
        func record(_ name: String, id: String = "b1000000-0000-4000-8000-000000000001") -> StaffReplicaCoreRecord {
            .init(kind: "customer", id: id, fields: ["name": .text(name)])
        }
        func server(_ value: StaffReplicaCoreRecord, revision: Int = 1, deleted: Bool = false) -> StaffReplicaSourceRemoteRecord {
            .init(companyID: binding.companyID, environment: binding.environment, replicaID: binding.replicaID,
                  kind: value.kind, id: value.id, revision: revision, deleted: deleted, fields: value.fields)
        }
        func journal() throws -> StaffReplicaSourceJournal {
            try saved[scope.key].map { try JSONDecoder().decode(StaffReplicaSourceJournal.self, from: $0) } ?? .init(scope: scope)
        }
        func store(_ journal: StaffReplicaSourceJournal) throws { saved[scope.key] = try JSONEncoder().encode(journal) }
        func dependencies() -> StaffReplicaSourceDependencies {
            .init(context: { self.context }, check: { context in
                guard self.authorized, context.scope == self.scope, context.stamp == self.context.stamp else { throw StaffReplicaSourceSyncError.access }
            }, capture: { _, _ in
                self.captures += 1
                return .init(source: .init(schema: StaffReplicaCoreSource.schemaVersion, coverage: StaffReplicaCoreSource.recordKinds, records: self.local),
                             token: Data("cursor-\(self.captures)".utf8), deletions: self.deleted)
            }, request: { path, method, body in
                defer { self.afterRequest?() }
                if method == "POST" {
                    let bytes = try #require(body), batch = try JSONDecoder().decode(StaffReplicaSourceBatch.self, from: bytes)
                    #expect(try self.journal().pending == batch)
                    self.posts.append(bytes); self.beforePost?()
                    if let receipt = self.operations[batch.operationID] { return receipt }
                    guard batch.expectedSequence == self.sequence else { throw StaffReplicaSourceRejected(code: "source_changed") }
                    for change in batch.changes {
                        let old = self.remote.first { $0.key == change.key }
                        guard (old?.revision ?? 0) == change.expectedRevision else { throw StaffReplicaSourceRejected(code: "record_changed") }
                        let next = self.server(.init(kind: change.kind, id: change.id, fields: change.action == "delete" ? old!.fields : change.fields),
                                              revision: change.expectedRevision + 1, deleted: change.action == "delete")
                        self.remote.removeAll { $0.key == change.key }; self.remote.append(next)
                    }
                    self.sequence += 1
                    let receipt = StaffReplicaSourceReceipt(operationID: batch.operationID, companyID: self.binding.companyID,
                        environment: self.binding.environment, replicaID: self.binding.replicaID, schema: batch.schema,
                        sequence: self.sequence, currentSequence: self.sequence,
                        changes: batch.changes.map { .init(kind: $0.kind, id: $0.id, revision: $0.expectedRevision + 1, deleted: $0.action == "delete") })
                    let data = try JSONEncoder().encode(receipt); self.operations[batch.operationID] = data
                    if self.loseReply { self.loseReply = false; throw StaffReplicaSourceSyncError.unavailable }
                    return data
                }
                self.reads += 1
                let query = Dictionary(uniqueKeysWithValues: URLComponents(string: path)!.queryItems!.map { ($0.name, $0.value!) })
                if let expected = query["sequence"], expected != String(self.sequence) { throw StaffReplicaSourceSyncError.sourceChanged }
                let records = self.remote.sorted { $0.key < $1.key }.filter { $0.key > (query["after"] ?? "") }
                let page = StaffReplicaSourcePage(schema: StaffReplicaCoreSource.schemaVersion, companyID: self.binding.companyID,
                    environment: self.binding.environment, replicaID: self.binding.replicaID, sequence: self.sequence,
                    authorizationSequence: self.sequence == 0 ? 0 : 1, records: Array(records.prefix(100)), nextCursor: records.count > 100 ? records[99].key : nil)
                return try JSONEncoder().encode(self.pageMutation?(page) ?? page)
            }, store: .init(read: { self.saved[$0] }, write: { key, data in
                self.writes += 1
                if self.failWrite == self.writes { throw StaffReplicaSourceSyncError.storage }
                self.saved[key] = data
            }), now: { self.now })
        }
        func coordinator() -> StaffReplicaSourceCoordinator { .init(dependencies: dependencies()) }
        func establish(_ name: String = "Original") async throws {
            local = [record(name)]; await coordinator().sync()
            #expect(try journal().baseline.count == 1); posts = []; reads = 0
        }
    }

    @Test func firstSavedSnapshotAndOriginalOperationAreDurableBeforePost() async throws {
        let h = Fixture(); h.local = [h.record("Original")]
        let c = h.coordinator(); await c.sync()
        #expect(h.posts.count == 1 && h.sequence == 1)
        #expect(try h.journal().pending == nil && h.journal().token != nil)
        #expect(c.lastConfirmedAt == h.now && c.conflicts.isEmpty)
    }
    @Test func unchangedRecordDoesNotPublishAgainButSavedEditUsesAcknowledgedRevision() async throws {
        let h = Fixture(); try await h.establish()
        await h.coordinator().sync(); #expect(h.posts.isEmpty)
        h.local = [h.record("Edited")]; await h.coordinator().sync()
        let batch = try JSONDecoder().decode(StaffReplicaSourceBatch.self, from: #require(h.posts.first))
        #expect(batch.expectedSequence == 1 && batch.changes[0].expectedRevision == 1)
        #expect(batch.changes[0].fields["name"] == .text("Edited"))
    }
    @Test func lostReplyAcrossRelaunchReplaysExactOriginalBeforeNewerEdit() async throws {
        let h = Fixture(); h.local = [h.record("Original")]; h.loseReply = true
        await h.coordinator().sync(); let original = try #require(h.posts.first)
        #expect(try h.journal().pending != nil && h.sequence == 1)
        h.local = [h.record("Later saved edit")]; await h.coordinator().sync()
        #expect(h.posts.count == 3 && h.posts[1] == original && h.posts[2] != original)
        #expect(h.sequence == 2 && h.operations.count == 2)
        #expect(try h.journal().baseline.values.first?.fields["name"] == .text("Later saved edit"))
    }
    @Test func storageFailureBeforeOriginalPostMakesNoExternalMutation() async throws {
        for write in 1...3 {
            let h = Fixture(); h.local = [h.record("Retained")]; h.failWrite = write
            await h.coordinator().sync(); #expect(h.posts.isEmpty && h.sequence == 0)
        }
    }
    @Test func failedReceiptSaveRetainsExactRecoverableRequest() async throws {
        let h = Fixture(); h.local = [h.record("Original")]; h.failWrite = 4
        await h.coordinator().sync(); #expect(try h.journal().pending != nil && h.sequence == 1)
        h.failWrite = nil; await h.coordinator().sync()
        #expect(h.posts.count == 2 && h.posts[0] == h.posts[1] && h.sequence == 1)
    }
    @Test func freshServerRevisionDoesNotAuthorizeOverwritingAnotherDevicesEdit() async throws {
        let h = Fixture(); try await h.establish()
        h.remote = [h.server(h.record("Other device"), revision: 2)]; h.sequence = 2
        h.local = [h.record("This device")]
        let c = h.coordinator(); await c.sync()
        #expect(h.posts.isEmpty && c.conflicts.count == 1)
        #expect(try h.journal().baseline.values.first?.revision == 1)
        await c.approve(try #require(c.conflicts.first))
        #expect(h.posts.count == 1 && h.remote[0].fields["name"] == .text("This device"))
    }
    @Test func changedRemoteInvalidatesExplicitComparisonBeforePublishing() async throws {
        let h = Fixture(); try await h.establish()
        h.local = [h.record("This device")]; h.remote = [h.server(h.record("Other device"), revision: 2)]; h.sequence = 2
        let c = h.coordinator(); await c.sync(); let original = try #require(c.conflicts.first)
        h.remote = [h.server(h.record("Even newer"), revision: 3)]; h.sequence = 3
        await c.approve(original)
        #expect(h.posts.isEmpty && c.conflicts.first?.remote.revision == 3)
    }
    @Test func unchangedLocalWaitsForCloudKitAndThenAdoptsMatchingRemoteWithoutWrite() async throws {
        let h = Fixture(); try await h.establish()
        h.remote = [h.server(h.record("Other device"), revision: 2)]; h.sequence = 2
        let c = h.coordinator(); await c.sync()
        #expect(h.posts.isEmpty && c.conflicts.isEmpty && c.message.contains("catch up"))
        h.local = [h.record("Other device")]; await c.sync()
        #expect(try h.posts.isEmpty && h.journal().baseline.values.first?.revision == 2)
    }
    @Test func missingLocalIsNotDeletionButRecordedDeletionUsesOriginalBaseline() async throws {
        let h = Fixture(); try await h.establish(); h.local = []
        await h.coordinator().sync(); #expect(h.posts.isEmpty)
        h.deleted = [h.record("Original").key]; await h.coordinator().sync()
        #expect(h.posts.count == 1 && h.remote[0].deleted)
        #expect(try h.journal().deletions.isEmpty)
    }
    @Test func firstDeviceBaselineCannotDeleteOrOverwriteUnobservedRemote() async throws {
        for deleting in [false, true] {
            let h = Fixture(); h.remote = [h.server(h.record("Existing"))]; h.sequence = 1
            if deleting { h.deleted = [h.record("Existing").key] } else { h.local = [h.record("Different")] }
            let c = h.coordinator(); await c.sync()
            #expect(h.posts.isEmpty && c.conflicts.count == 1)
        }
    }
    @Test func serverTombstoneIsNotImplicitlyRestoredByStaleLiveLocalRecord() async throws {
        let h = Fixture(); try await h.establish()
        h.remote = [h.server(h.record("Original"), revision: 2, deleted: true)]; h.sequence = 2
        h.local = [h.record("Changed after removal")]
        let c = h.coordinator(); await c.sync()
        #expect(h.posts.isEmpty && c.conflicts.count == 1)
        await c.approve(try #require(c.conflicts.first))
        let batch = try JSONDecoder().decode(StaffReplicaSourceBatch.self, from: #require(h.posts.first))
        #expect(batch.changes.first?.action == "restore")
    }
    @Test func explicitRejectedBatchIsArchivedThenSafelyReconciledWithNewOperation() async throws {
        let h = Fixture(); try await h.establish(); h.local = [h.record("Saved")]
        h.beforePost = { h.sequence = 2; h.beforePost = nil }
        await h.coordinator().sync()
        #expect(try h.journal().rejected.count == 1 && h.journal().pending == nil)
        let rejected = try #require(h.posts.first)
        await h.coordinator().sync()
        #expect(h.posts.count == 2 && h.posts[1] != rejected && h.sequence == 3)
        #expect(try StaffReplicaSourceCoordinator.encode(h.journal().rejected[0]) == rejected)
    }
    @Test func accountSwitchAfterReadCannotPostOrAcknowledgeOtherWorkspace() async throws {
        let h = Fixture(); h.local = [h.record("Retained")]
        h.afterRequest = { h.authorized = false }
        let c = h.coordinator(); await c.sync()
        #expect(h.posts.isEmpty && c.conflicts.isEmpty)
    }
    @Test func replacementStoreDoesNotReplayOldStorePendingOrToken() async throws {
        let h = Fixture(); h.local = [h.record("Old store")]; h.loseReply = true
        await h.coordinator().sync(); let oldKey = h.scope.key, oldBytes = h.saved[oldKey]
        h.storeID = UUID().uuidString; h.local = []
        await h.coordinator().sync()
        #expect(h.posts.count == 1 && h.saved[oldKey] == oldBytes && h.saved.count == 2)
    }
    @Test func consistentPaginationReadsAllRecordsAndRejectsMalformedOrder() async throws {
        let h = Fixture()
        h.remote = (1...201).map { h.server(h.record("Customer \($0)", id: String(format: "b1000000-0000-4000-8000-%012d", $0))) }
        h.sequence = 1; h.local = h.remote.compactMap(\.live)
        await h.coordinator().sync()
        #expect(try h.reads == 4 && h.posts.isEmpty && h.journal().baseline.count == 201)
        h.reads = 0
        h.pageMutation = { page in
            .init(schema: page.schema, companyID: page.companyID, environment: page.environment, replicaID: page.replicaID,
                  sequence: page.sequence, authorizationSequence: page.authorizationSequence, records: page.records.reversed(), nextCursor: page.nextCursor)
        }
        await h.coordinator().sync(); #expect(h.reads == 1 && h.posts.isEmpty)
    }
    @Test func sourceAdvancingDuringReadDoesNotCommitMixedBaseline() async throws {
        let h = Fixture(); h.remote = [h.server(h.record("Original"))]; h.sequence = 1; h.local = h.remote.compactMap(\.live)
        h.afterRequest = { h.sequence += 1 }
        await h.coordinator().sync()
        #expect(try h.posts.isEmpty && h.journal().baseline.isEmpty)
    }
    @Test func largeLocalCaptureContinuesInBoundedBatches() async throws {
        let h = Fixture()
        h.local = (1...201).map { h.record("Customer \($0)", id: String(format: "b1000000-0000-4000-8000-%012d", $0)) }
        let c = h.coordinator(); await c.sync(); #expect(c.hasMore && h.remote.count == 100)
        await c.sync(); #expect(c.hasMore && h.remote.count == 200)
        await c.sync(); #expect(!c.hasMore && h.remote.count == 201 && h.sequence == 3)
    }
    @Test func sourceHTTPPolicyDoesNotOpenOtherEndpointsOrEncodedQueries() throws {
        let h = Fixture(), path = StaffReplicaSourceTransportPolicy.path(scope: h.scope)
        #expect(StaffReplicaSourceTransportPolicy.allows(path: path, method: "GET", body: nil))
        for invalid in [path + "&companyID=" + h.binding.companyID.uuidString.lowercased(), path + "&after=customer:" + h.record("A").id,
                        path + "&secret=1", "https://elsewhere.invalid" + path, path + "#x", path.replacingOccurrences(of: "companyID", with: "%63ompanyID")] {
            #expect(!StaffReplicaSourceTransportPolicy.allows(path: invalid, method: "GET", body: nil))
        }
        #expect(!StaffReplicaSourceTransportPolicy.allows(path: path, method: "POST", body: Data("{}".utf8)))
        #expect(!StaffReplicaSourceTransportPolicy.allows(path: StaffReplicaSourceTransportPolicy.root, method: "DELETE", body: nil))
    }
    @Test func corruptPendingScopeIsRetainedWithoutReplay() async throws {
        let h = Fixture(); h.local = [h.record("Retained")]; h.loseReply = true
        await h.coordinator().sync()
        var journal = try h.journal()
        let wrong = StaffReplicaSourceScope(backendOrigin: h.scope.backendOrigin, actorEmail: h.scope.actorEmail,
            binding: .init(companyID: UUID(), containerID: h.binding.containerID, environment: h.binding.environment,
                           replicaID: h.binding.replicaID, cloudAccountHash: h.binding.cloudAccountHash, approvedAt: h.binding.approvedAt), storeUUID: h.storeID)
        journal.pending = .init(scope: wrong, sequence: 0, changes: journal.pending!.changes)
        try h.store(journal); let original = h.saved[h.scope.key]
        await h.coordinator().sync()
        #expect(h.posts.count == 1 && h.saved[h.scope.key] == original)
    }
    @Test func changedLocalInvalidatesPriorConflictApproval() async throws {
        let h = Fixture(); try await h.establish()
        h.local = [h.record("Local review")]; h.remote = [h.server(h.record("Remote review"), revision: 2)]; h.sequence = 2
        let c = h.coordinator(); await c.sync(); let original = try #require(c.conflicts.first)
        h.local = [h.record("Local edit after comparison")]
        await c.approve(original)
        #expect(h.posts.isEmpty && c.conflicts.first?.local?.fields["name"] == .text("Local edit after comparison"))
    }
    @Test func missingRetainedServerRecordCannotBeRecreatedAsNew() async throws {
        let h = Fixture(); try await h.establish()
        h.remote = []; h.local = [h.record("Local edit")]
        await h.coordinator().sync()
        #expect(try h.posts.isEmpty && h.journal().baseline.count == 1)
    }
}
