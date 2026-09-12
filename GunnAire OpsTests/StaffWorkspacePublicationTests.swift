import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct StaffWorkspacePublicationTests {
    typealias Contract = StaffWorkspacePublicationContract
    typealias Publisher = StaffWorkspacePublicationCoordinator
    @MainActor final class Fixture {
        let authority = StaffReplicaSourceSyncTests.Fixture()
        var local: [StaffWorkspaceModelRecord] = []
        var remote: [StaffWorkspacePublishedRecord] = []
        var saved: [String: Data] = [:]
        var posts: [Data] = []
        var operations: [String: Data] = [:]
        var sequence = 0, reads = 0, captures = 0, writes = 0, pageLimit = 100
        var loseReply = false, failCapture = false
        var failWrite: Int?
        var rejection: String?
        var afterRequest: (() -> Void)?
        var duringPost: (() async throws -> Void)?
        var mutateResponse: ((Data, String) throws -> Data)?
        var prepare: (() throws -> StaffWorkspaceSourceJournal)?
        var diskStorage: SharedTimeLocalStore?
        var scope: StaffReplicaSourceScope { authority.scope }
        var context: StaffReplicaSourceContext { authority.context }
        func record(_ name: String) throws -> StaffWorkspaceModelRecord {
            try StaffWorkspaceModelCodecs.vendor.encode(Vendor(name: name))
        }
        func revised(_ record: StaffWorkspaceModelRecord, name: String) -> StaffWorkspaceModelRecord {
            var fields = record.fields; fields["name"] = .text(name)
            return .init(version: 1, kind: record.kind, id: record.id, fields: fields)
        }
        func server(_ record: StaffWorkspaceModelRecord, revision: Int = 1, deleted: Bool = false) -> StaffWorkspacePublishedRecord {
            .init(companyID: scope.binding.companyID.uuidString.lowercased(), environment: scope.binding.environment,
                replicaID: scope.binding.replicaID.uuidString.lowercased(), schema: Contract.schema, schemaDigest: Contract.schemaDigest,
                kind: record.kind, id: record.id.uuidString.lowercased(), revision: revision, deleted: deleted, fields: record.fields)
        }
        func journal() throws -> StaffWorkspacePublicationJournal {
            try storage.read(Publisher.key(scope)).map { try Contract.decode(StaffWorkspacePublicationJournal.self, from: $0,
                maximum: Contract.maximumScanBytes) } ?? .init(scope: scope)
        }
        func store(_ journal: StaffWorkspacePublicationJournal) throws { try storage.write(Publisher.key(scope), Contract.encode(journal)) }
        var storage: SharedTimeLocalStore {
            if let diskStorage { return diskStorage }
            return .init(read: { self.saved[$0] }, write: { key, data in
                self.writes += 1
                if self.writes == self.failWrite { throw StaffReplicaSourceSyncError.storage }
                self.saved[key] = data
            })
        }
        func dependencies() -> StaffWorkspacePublicationDependencies {
            .init(check: authority.dependencies().check, prepare: { _ in
                self.captures += 1
                if self.failCapture { throw StaffReplicaSourceSyncError.history }
                if let prepare = self.prepare { return try prepare() }
                return .init(version: 1, scope: self.scope, records: self.local.sorted { StaffWorkspaceHistory.key($0) < StaffWorkspaceHistory.key($1) },
                    cursor: nil, deletionKeys: [])
            }, request: { path, method, body in
                defer { self.afterRequest?() }
                #expect(StaffWorkspacePublicationTransportPolicy.allows(path: path, method: method, body: body))
                let output: Data
                if method == "POST" {
                    let body = try #require(body)
                    #expect(try self.journal().pending?.body == body) // Durable before network.
                    let batch = try Contract.decode(StaffWorkspacePublicationBatch.self, from: body)
                    try batch.validate(self.scope); self.posts.append(body)
                    try await self.duringPost?()
                    if let rejection = self.rejection { throw StaffReplicaSourceRejected(code: rejection) }
                    if let prior = self.operations[batch.operationID] {
                        var object = try #require(JSONSerialization.jsonObject(with: prior) as? [String: Any])
                        object["currentSequence"] = self.sequence
                        output = try JSONSerialization.data(withJSONObject: object)
                    } else {
                        guard batch.expectedSequence == self.sequence else { throw StaffReplicaSourceRejected(code: "source_changed") }
                        var records = self.remote
                        for change in batch.changes {
                            let old = records.first { $0.key == change.key }
                            guard (old?.revision ?? 0) == change.expectedRevision else { throw StaffReplicaSourceRejected(code: "record_changed") }
                            guard change.action == "restore" ? old?.deleted == true : old?.deleted != true else {
                                throw StaffReplicaSourceRejected(code: "deletion_changed")
                            }
                            let fields = change.action == "delete" ? try #require(old?.fields) : change.fields
                            let model = StaffWorkspaceModelRecord(version: 1, kind: change.kind, id: try #require(UUID(uuidString: change.id)), fields: fields)
                            records.removeAll { $0.key == change.key }
                            records.append(self.server(model, revision: change.expectedRevision + 1, deleted: change.action == "delete"))
                        }
                        self.sequence += 1; self.remote = records
                        let receipt = StaffWorkspacePublicationReceipt(companyID: batch.companyID, environment: batch.environment,
                            replicaID: batch.replicaID, schema: batch.schema, schemaDigest: batch.schemaDigest, operationID: batch.operationID,
                            sequence: self.sequence, currentSequence: self.sequence,
                            changes: batch.changes.map { .init(kind: $0.kind, id: $0.id, revision: $0.expectedRevision + 1, deleted: $0.action == "delete") })
                        output = try Contract.encode(receipt); self.operations[batch.operationID] = output
                        if self.loseReply { self.loseReply = false; throw StaffReplicaSourceSyncError.unavailable }
                    }
                } else {
                    self.reads += 1
                    let query = Dictionary(uniqueKeysWithValues: try #require(URLComponents(string: path)?.queryItems).map { ($0.name, $0.value ?? "") })
                    if let expected = query["sequence"], expected != String(self.sequence) { throw StaffReplicaSourceSyncError.sourceChanged }
                    let rows = self.remote.sorted { $0.key < $1.key }.filter { $0.key > (query["after"] ?? "") }
                    output = try Contract.encode(StaffWorkspacePublicationPage(companyID: self.scope.binding.companyID.uuidString.lowercased(),
                        environment: self.scope.binding.environment, replicaID: self.scope.binding.replicaID.uuidString.lowercased(),
                        schema: Contract.schema, schemaDigest: Contract.schemaDigest, sequence: self.sequence,
                        records: Array(rows.prefix(self.pageLimit)), nextCursor: rows.count > self.pageLimit ? rows[self.pageLimit - 1].key : nil))
                }
                return try self.mutateResponse?(output, method) ?? output
            }, store: storage, now: { self.authority.now })
        }
        func publisher() -> Publisher { .init(dependencies: dependencies()) }
        func establish() async throws {
            _ = try await publisher().synchronize(context)
            posts = []; reads = 0; writes = 0
        }
    }

    @Test func all32KindsPublishWithExactTypedFieldsAndDurableReceipt() async throws {
        let h = Fixture(); h.local = try StaffWorkspaceFullModelTests().encodedFixtures()
        let publisher = h.publisher(), result = try await publisher.synchronize(h.context)
        #expect(result.hasMore && result.conflicts.isEmpty && result.waitingForCloudKit == 0)
        #expect(h.posts.count == 1 && h.operations.count == 1 && h.remote.count == 32)
        #expect(h.remote.reduce(0) { $0 + $1.fields.count } == 561)
        #expect(Set(h.remote.map(\.kind)) == Contract.kinds)
        #expect(h.remote.compactMap(\.live).sorted { $0.kind < $1.kind } == h.local.sorted { $0.kind < $1.kind })
        #expect(try h.journal().pending == nil && h.journal().baseline.count == 32)
        let next = try await publisher.synchronize(h.context)
        #expect(!next.hasMore && h.posts.count == 1 && h.reads == 3)
    }

    @Test func lostReplyReplaysIdenticalBytesBeforeFailingNewHistoryCapture() async throws {
        let h = Fixture(); h.local = [try h.record("Original")]; h.loseReply = true
        await #expect(throws: StaffReplicaSourceSyncError.unavailable) { try await h.publisher().synchronize(h.context) }
        let original = try #require(h.journal().pending?.body)
        h.failCapture = true
        await #expect(throws: StaffReplicaSourceSyncError.history) { try await h.publisher().synchronize(h.context) }
        #expect(h.posts == [original, original] && h.operations.count == 1 && h.sequence == 1)
        #expect(try h.journal().pending == nil && h.journal().baseline.count == 1)
    }

    @Test(arguments: [2, 3]) func failedPendingOrAcknowledgementSaveNeverLosesOriginal(write: Int) async throws {
        let h = Fixture(); h.local = [try h.record("Original")]; h.failWrite = write
        await #expect(throws: StaffReplicaSourceSyncError.storage) { try await h.publisher().synchronize(h.context) }
        #expect(h.posts.count == (write == 2 ? 0 : 1))
        let first = h.posts.first; h.failWrite = nil
        _ = try await h.publisher().synchronize(h.context)
        #expect(h.operations.count == 1 && h.sequence == 1)
        if let first { #expect(h.posts == [first, first]) }
        #expect(try h.journal().pending == nil)
    }

    @Test(arguments: ["source_changed", "record_changed", "deletion_changed", "schema_changed", "replica_changed", "operation_changed"])
    func onlyProvenRejectionsArchiveOriginal(code: String) async throws {
        let h = Fixture(); h.local = [try h.record("Original")]; h.rejection = code
        await #expect(throws: (any Error).self) { try await h.publisher().synchronize(h.context) }
        let journal = try h.journal(), original = try #require(h.posts.first)
        if ["source_changed", "record_changed", "deletion_changed"].contains(code) {
            #expect(journal.pending == nil && journal.rejected.map(\.body) == [original])
        } else { #expect(journal.pending?.body == original && journal.rejected.isEmpty) }
        #expect(h.remote.isEmpty && journal.baseline.isEmpty)
    }

    @Test func shortPagesAndEndFenceReadEveryOriginalWithoutRepeatedFullScans() async throws {
        let h = Fixture(); h.local = try (0..<7).map { try h.record("Original \($0)") }
        h.remote = h.local.map { h.server($0) }; h.sequence = 1; h.pageLimit = 2
        let publisher = h.publisher()
        _ = try await publisher.synchronize(h.context)
        let baseline = try h.journal().baseline
        #expect(h.reads == 5 && h.posts.isEmpty && baseline.count == 7)
        _ = try await publisher.synchronize(h.context)
        #expect(h.reads == 6 && h.posts.isEmpty)
        h.sequence += 1
        await #expect(throws: StaffReplicaSourceSyncError.sourceChanged) { try await publisher.synchronize(h.context) }
        _ = try await publisher.synchronize(h.context)
        #expect(h.reads == 12)
    }

    @Test func foregroundBatchLimitRetainsRemainingWorkAndReusesOnlyFencedCache() async throws {
        let h = Fixture(); h.local = try (0..<805).map { try h.record("Vendor \($0)") }
        let publisher = h.publisher()
        #expect(try await publisher.synchronize(h.context).hasMore)
        #expect(h.posts.count == 8 && h.remote.count == 800 && h.reads == 2)
        #expect(try await publisher.synchronize(h.context).hasMore)
        #expect(h.posts.count == 9 && h.remote.count == 805 && h.reads == 3)
        #expect(!(try await publisher.synchronize(h.context)).hasMore)
        #expect(h.posts.count == 9 && h.reads == 4)
    }

    @Test func absenceDoesNotDeleteAndConflictApprovalRequiresBothExactVersions() async throws {
        let h = Fixture(), original = try h.record("Original"); h.local = [original]; try await h.establish()
        h.local = []
        let missing = try await h.publisher().synchronize(h.context)
        #expect(missing.waitingForCloudKit == 1 && h.posts.isEmpty && !h.remote[0].deleted)
        h.local = [h.revised(original, name: "This device")]
        h.remote = [h.server(h.revised(original, name: "Other device"), revision: 2)]; h.sequence += 1
        let publisher = h.publisher(), review = try await publisher.synchronize(h.context)
        let conflict = try #require(review.conflicts.first)
        try publisher.approve(conflict, context: h.context)
        h.local = [h.revised(original, name: "Newer local edit")]
        #expect(try await publisher.synchronize(h.context).conflicts.count == 1)
        #expect(h.posts.isEmpty)
        let fresh = try await publisher.synchronize(h.context)
        try publisher.approve(try #require(fresh.conflicts.first), context: h.context)
        _ = try await publisher.synchronize(h.context)
        #expect(h.posts.count == 1 && h.remote[0].fields["name"] == .text("Newer local edit"))
    }

    @Test func remoteOnlyEditWaitsForCloudKitAndRestoreRequiresExplicitReview() async throws {
        let h = Fixture(), original = try h.record("Original"); h.local = [original]; try await h.establish()
        h.remote = [h.server(h.revised(original, name: "CloudKit edit"), revision: 2)]; h.sequence += 1
        let waiting = try await h.publisher().synchronize(h.context)
        #expect(waiting.waitingForCloudKit == 1 && waiting.conflicts.isEmpty && h.posts.isEmpty)
        h.remote = [h.server(original, revision: 3, deleted: true)]; h.sequence += 1
        let publisher = h.publisher(), result = try await publisher.synchronize(h.context)
        let conflict = try #require(result.conflicts.first)
        #expect(conflict.remote.deleted && !conflict.deletion && h.posts.isEmpty)
        try publisher.approve(conflict, context: h.context)
        _ = try await publisher.synchronize(h.context)
        #expect(!h.remote[0].deleted && h.remote[0].revision == 4)
        #expect(try Contract.decode(StaffWorkspacePublicationBatch.self, from: h.posts[0]).changes[0].action == "restore")
    }

    @Test func revocationAfterAcceptedPostRetainsOriginalUntilVerifiedRecovery() async throws {
        let h = Fixture(); h.local = [try h.record("Original")]
        h.afterRequest = { if !h.posts.isEmpty { h.authority.authorized = false } }
        await #expect(throws: StaffReplicaSourceSyncError.access) { try await h.publisher().synchronize(h.context) }
        let original = try #require(h.journal().pending?.body)
        await #expect(throws: StaffReplicaSourceSyncError.access) { try await h.publisher().synchronize(h.context) }
        #expect(h.posts.count == 1)
        h.afterRequest = nil; h.authority.authorized = true
        _ = try await h.publisher().synchronize(h.context)
        #expect(h.posts == [original, original] && h.operations.count == 1)
    }

    @Test func malformedReceiptKeepsOriginalAndScopeCorruptionNeverResetsQueue() async throws {
        let h = Fixture(); h.local = [try h.record("Original")]
        h.mutateResponse = { data, method in
            guard method == "POST" else { return data }
            var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["operationID"] = UUID().uuidString.lowercased()
            return try JSONSerialization.data(withJSONObject: object)
        }
        await #expect(throws: StaffReplicaSourceSyncError.invalid) { try await h.publisher().synchronize(h.context) }
        let oldKey = Publisher.key(h.scope), original = try #require(h.saved[oldKey])
        h.authority.storeID = UUID().uuidString
        h.saved[Publisher.key(h.scope)] = original
        await #expect(throws: StaffReplicaSourceSyncError.storage) { try await h.publisher().synchronize(h.context) }
        #expect(h.posts.count == 1 && h.saved[oldKey] == original && h.saved[Publisher.key(h.scope)] == original)
    }

    @Test func duplicateAndUnknownEnvelopeFieldsNeverBecomeSuccessfulPages() async throws {
        for addition in [#""sequence":0,"#, #""sequen\u0063e":0,"#, #""unknown":true,"#] {
            let h = Fixture()
            h.mutateResponse = { data, _ in Data(("{" + addition + String(decoding: data, as: UTF8.self).dropFirst()).utf8) }
            await #expect(throws: (any Error).self) { try await h.publisher().synchronize(h.context) }
            #expect(h.saved.isEmpty && h.posts.isEmpty)
        }
    }

    @Test func fullTransportRejectsForeignLegacyDuplicateAndAmbiguousQueries() {
        let h = Fixture(), path = StaffWorkspacePublicationTransportPolicy.path(scope: h.scope)
        #expect(StaffWorkspacePublicationTransportPolicy.allows(path: path, method: "GET", body: nil))
        for invalid in ["https://example.invalid" + path, path + "&companyID=" + h.scope.binding.companyID.uuidString.lowercased(),
                        path + "#x", path + "&after=vendor:bad", path + "&sequence=01", path + "&admin=true",
                        path.replacingOccurrences(of: "full-records", with: "records"), path.replacingOccurrences(of: "companyID", with: "%63ompanyID")] {
            #expect(!StaffWorkspacePublicationTransportPolicy.allows(path: invalid, method: "GET", body: nil))
        }
        #expect(!StaffWorkspacePublicationTransportPolicy.allows(path: path, method: "POST", body: Data("{}".utf8)))
    }

    @Test func concurrentPublisherCannotReplaceOriginalInFlightJournal() async throws {
        let h = Fixture(); h.local = [try h.record("Original")]
        h.duringPost = { await #expect(throws: (any Error).self) { try await h.publisher().synchronize(h.context) } }
        _ = try await h.publisher().synchronize(h.context)
        #expect(h.operations.count == 1 && h.posts.count == 1)
    }

    @Test func actualSQLiteDeleteSurvivesLostReplyAndRetainsOriginalFields() async throws {
        let history = StaffWorkspaceHistoryTests(), root = try history.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Owner.store"), container = try history.container(url)
        let vendor = Vendor(name: "Saved original supplier")
        container.mainContext.insert(vendor); try container.mainContext.save()
        let h = Fixture(); h.authority.storeID = try history.identity(url)
        h.prepare = { try StaffWorkspaceSourceStaging.prepare(container: container, scope: h.scope, store: h.storage,
            check: { try h.authority.dependencies().check(h.context) }) }
        try await h.establish()
        let originalFields = h.remote[0].fields
        container.mainContext.delete(vendor); try container.mainContext.save(); h.loseReply = true
        await #expect(throws: StaffReplicaSourceSyncError.unavailable) { try await h.publisher().synchronize(h.context) }
        let original = try #require(h.journal().pending?.body)
        _ = try await h.publisher().synchronize(h.context)
        #expect(h.posts == [original, original] && h.remote[0].deleted && h.remote[0].fields == originalFields)
        #expect(try h.journal().baseline[h.remote[0].key]?.fieldsDigest == Contract.digest(originalFields))
        #expect(try StaffWorkspaceSourceJournal.decode(#require(h.saved[StaffWorkspaceSourceStaging.key(h.scope)]), scope: h.scope).deletionKeys == [h.remote[0].key])
    }

    @Test func encryptedJournalReopensOriginalRequestAndMissingKeyCannotResetIt() async throws {
        let root = try StaffWorkspaceHistoryTests().directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("OwnerPublication", isDirectory: true)
        let key = Data(repeating: 87, count: 32), h = Fixture()
        func store() -> SharedTimeLocalStore {
            .encrypted(directory: directory, maximumBytes: Contract.maximumScanBytes, key: { _ in key })
        }
        h.diskStorage = store(); h.local = [try h.record("Private fixture supplier")]; h.loseReply = true
        await #expect(throws: StaffReplicaSourceSyncError.unavailable) { try await h.publisher().synchronize(h.context) }
        let original = try #require(h.journal().pending?.body)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let file = try #require(files.first), sealed = try Data(contentsOf: file)
        #expect(sealed.range(of: original) == nil && sealed.range(of: Data("Private fixture supplier".utf8)) == nil)
        h.diskStorage = .encrypted(directory: directory, maximumBytes: Contract.maximumScanBytes,
            key: { _ in throw StaffReplicaSourceSyncError.storage })
        await #expect(throws: StaffReplicaSourceSyncError.storage) { try await h.publisher().synchronize(h.context) }
        #expect(try Data(contentsOf: file) == sealed)
        #expect(h.posts == [original])
        h.diskStorage = store() // New store closures and publisher, same encrypted original on disk.
        _ = try await h.publisher().synchronize(h.context)
        #expect(h.posts == [original, original] && h.operations.count == 1 && h.sequence == 1)
        #expect(try h.journal().pending == nil)
        #expect(h.saved.isEmpty)
    }

    @Test func legacyOriginalRecoversBeforeFullPublicationAndNewCoreCapture() async throws {
        let h = Fixture(), core = h.authority
        core.local = [core.record("Original customer")]; core.loseReply = true
        await core.coordinator().sync()
        let original = try #require(core.posts.first)
        #expect(try core.journal().pending != nil)
        h.local = [try h.record("Original supplier")]
        h.prepare = {
            #expect(core.posts == [original, original] && core.captures == 1)
            let pending = try core.journal().pending
            #expect(pending == nil)
            return .init(version: 1, scope: h.scope, records: h.local, cursor: nil, deletionKeys: [])
        }
        var dependencies = core.dependencies(); dependencies.fullWorkspace = h.publisher()
        let coordinator = StaffReplicaSourceCoordinator(dependencies: dependencies)
        await coordinator.sync()
        #expect(coordinator.hasMore && h.posts.count == 1 && core.captures == 1)
        h.prepare = nil
        await coordinator.sync()
        #expect(!coordinator.hasMore && h.posts.count == 1 && core.captures == 2)
        #expect(core.posts == [original, original])
    }

    @Test func ownerReviewHandoffApprovesOnlyTheDisplayedConflictThenResumesCoreSync() async throws {
        let h = Fixture(), original = try h.record("This device")
        h.local = [original]; h.remote = [h.server(h.revised(original, name: "Other device"))]; h.sequence = 1
        var dependencies = h.authority.dependencies(); dependencies.fullWorkspace = h.publisher()
        let source = StaffReplicaSourceCoordinator(dependencies: dependencies)
        await source.sync()
        let conflict = try #require(source.workspaceConflicts.first)
        #expect(h.posts.isEmpty && h.authority.captures == 0)
        await source.approveWorkspace(conflict)
        #expect(h.posts.count == 1 && source.workspaceConflicts.isEmpty && source.hasMore)
        await source.sync()
        #expect(!source.hasMore && h.authority.captures == 1)
        await source.approveWorkspace(conflict)
        #expect(h.posts.count == 1)
        source.clearDisplay()
        #expect(source.workspaceConflicts.isEmpty)
    }

    @Test func ownerEditArrivingDuringServerReadCannotHandOffAnOutdatedSnapshot() async throws {
        let h = Fixture(), original = try h.record("Original saved supplier")
        h.local = [original]; h.remote = [h.server(original)]; h.sequence = 1
        var edited = false
        h.afterRequest = {
            if !edited { h.local = [h.revised(original, name: "New saved edit")]; edited = true }
        }
        var dependencies = h.authority.dependencies(); dependencies.fullWorkspace = h.publisher()
        let source = StaffReplicaSourceCoordinator(dependencies: dependencies)
        await source.sync()
        #expect(source.hasMore && h.authority.captures == 0 && h.posts.isEmpty)
        h.afterRequest = nil
        await source.sync()
        #expect(source.hasMore && h.authority.captures == 0 && h.posts.count == 1)
        await source.sync()
        #expect(!source.hasMore && h.authority.captures == 1 && h.posts.count == 1)
        #expect(h.remote[0].fields["name"] == .text("New saved edit"))
    }

    @Test func reviewFormatsSavedDetailsWithoutRawJSONOrFullRecordIdentifiers() throws {
        typealias Review = StaffWorkspacePublicationReview
        #expect(Review.label("billingSnapshotJSON") == "Billing Snapshot")
        for field in ["billingSnapshotJSON", "notes"] {
            let text = Review.value(.text(#"{"private":{"saved":true}}"#), field: field)
            #expect(!text.contains("{") && !text.contains("private") && text.contains("original workspace"))
        }
        #expect(Review.value(.flag(true), field: "active") == "Yes")
        #expect(Review.value(.null, field: "name") == "Not set")
        #expect(Review.value(nil, field: "name") == "Not present")
        let id = UUID()
        #expect(!Review.value(.identifier(id), field: "customerID").contains(id.uuidString))
        let h = Fixture(), model = try h.record("A supplier")
        let conflict = StaffWorkspacePublicationConflict(local: model, remote: h.server(model, deleted: true), deletion: false)
        #expect(Review.action(conflict) == "Restore Server Copy")
        #expect(Review.changedFields(conflict).isEmpty)
        let deletion = StaffWorkspacePublicationConflict(local: nil, remote: h.server(model), deletion: true)
        #expect(Review.action(deletion) == "Apply Saved Deletion")
        #expect(Review.changedFields(deletion).count == model.fields.count)
    }
}
