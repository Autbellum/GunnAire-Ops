import Foundation
import XCTest
@testable import GunnAire_Ops

final class StaffWorkspaceContentCoordinatorTests: XCTestCase {
    struct RoleVector: Codable {
        let selectionRequest: StaffWorkspaceSelectionRequest
        let selectionReceipt: StaffWorkspaceSelectionReceipt
        let index: [StaffWorkspaceSelectionIndex]
        let contentReceipt: StaffWorkspaceContentReceipt
        let payloadUtf8: String
    }
    struct Vector: Decodable {
        let source: [StaffWorkspacePublishedRecord]
        let roles: [String: RoleVector]
    }
    @MainActor final class Fixture {
        let authority: StaffReplicaAutomaticDeliveryTests.Fixture
        let vector: Vector
        let role: AppUserRole
        var saved: [String: Data] = [:]
        var writes = 0, pageSize = 100, head = 1
        var failWrite: Int?, loseWrite: Int?
        var lostSelection = false, lostContent = false, failChunk = false
        var allowed = true
        var calls: [(String, String, Data?)] = []
        var afterRequest: ((String) -> Void)?
        var mutateResponse: ((String, Data) throws -> Data)?
        var disk: SharedTimeLocalStore?
        var source: StaffReplicaSourceContext { authority.source }
        var row: RoleVector { vector.roles[role.rawValue]! }
        var plan: CloudKitStaffSharePlan { authority.plans[0] }
        var key: String { StaffWorkspaceContentCoordinator.key(source.scope, plan.id) }
        var now: Date { authority.cloud.base.now }
        init(_ role: AppUserRole = .fieldTechnician) throws {
            self.role = role
            authority = try .init()
            let url = try XCTUnwrap(Bundle(for: StaffWorkspaceContentCoordinatorTests.self).url(forResource: "NativeFullContentInterop", withExtension: "json"))
            vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
            authority.plans = [try authority.cloud.base.plan(["memberRole": role.rawValue, "projectionPolicy": CloudKitStaffSharePlan.policy(for: role.rawValue)!])]
        }
        func cleanup() { authority.cleanup() }
        var stage: StaffWorkspaceSourceJournal {
            .init(version: 1, scope: source.scope, records: vector.source.compactMap(\.live), cursor: nil, deletionKeys: [])
        }
        var published: StaffWorkspacePublicationSummary {
            .init(conflicts: [], waitingForCloudKit: 0, hasMore: false, lastConfirmedAt: now,
                  preparedStage: stage, sourceSequence: 1, publishedRecords: vector.source)
        }
        var store: SharedTimeLocalStore {
            .init(read: { try self.disk?.read($0) ?? self.saved[$0] }, write: { key, value in
                self.writes += 1
                if self.failWrite == self.writes { throw StaffReplicaDeliveryError.storage }
                if let disk = self.disk { try disk.write(key, value) } else { self.saved[key] = value }
                if self.loseWrite == self.writes { throw StaffReplicaDeliveryError.storage }
            })
        }
        func journal() throws -> StaffWorkspaceContentJournal? {
            try store.read(key).map { try StaffWorkspacePublicationContract.decode(StaffWorkspaceContentJournal.self, from: $0, maximum: 40 * 1024 * 1024) }
        }
        func modified<T: Codable>(_ value: T, _ changes: [String: Any]) throws -> Data {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(value)) as? [String: Any])
            object.merge(changes) { _, next in next }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        func response(_ path: String, method: String, body: Data?) throws -> Data {
            XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: path, method: method, body: body))
            calls.append((path, method, body))
            let url = try XCTUnwrap(URLComponents(string: path))
            let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value!) })
            let wire: Data
            if method == "POST", url.path.hasSuffix("/full-selections") {
                XCTAssertEqual(try journal()?.pending?.requestBytes, body)
                XCTAssertEqual(try JSONDecoder().decode(StaffWorkspaceSelectionRequest.self, from: XCTUnwrap(body)), row.selectionRequest)
                if lostSelection { lostSelection = false; throw StaffReplicaDeliveryError.unavailable }
                wire = try modified(row.selectionReceipt, ["currentSourceSequence": head, "sourceCurrent": head == 1])
            } else if method == "POST" {
                XCTAssertEqual(try journal()?.pending?.contentRequestBytes, body)
                if lostContent { lostContent = false; throw StaffReplicaDeliveryError.unavailable }
                wire = try modified(row.contentReceipt, ["currentSourceSequence": head, "sourceCurrent": head == 1])
            } else if url.path.hasSuffix("/records") {
                let all = row.index.filter { $0.key > (query["after"] ?? "") }
                let page = Array(all.prefix(pageSize))
                wire = try StaffWorkspacePublicationContract.encode(StaffWorkspaceSelectionPage(receipt: row.selectionReceipt,
                    records: page, nextCursor: all.count > page.count ? page.last?.key : nil))
            } else if url.path.hasSuffix("/chunks") {
                if failChunk { throw StaffReplicaDeliveryError.unavailable }
                let bytes = Data(row.payloadUtf8.utf8), offset = Int(query["offset"]!)!
                let part = bytes.subdata(in: offset..<min(bytes.count, offset + row.contentReceipt.chunkBytes))
                let end = offset + part.count
                let chunk = StaffWorkspaceContentChunk(receipt: row.contentReceipt, offset: offset, nextOffset: end < bytes.count ? end : nil,
                    chunkSHA256: StaffReplicaManifest.hash(part), payloadBase64: part.base64EncodedString())
                wire = try StaffWorkspacePublicationContract.encode(chunk)
            } else {
                wire = try modified(row.contentReceipt, ["currentSourceSequence": head, "sourceCurrent": head == 1])
            }
            let result = try mutateResponse?(path, wire) ?? wire
            afterRequest?(path)
            return result
        }
        func dependencies() -> StaffWorkspaceContentDependencies {
            .init(setup: { (try self.authority.cloud.context(), self.authority.plans) }, check: { source in
                guard self.allowed, source.scope == self.source.scope, source.stamp == self.source.stamp else { throw StaffReplicaDeliveryError.access }
            }, request: { try self.response($0, method: $1, body: $2) }, store: store, now: { self.now },
                operation: { UUID(uuidString: self.row.selectionRequest.operationID)! })
        }
        func run() async throws -> StaffWorkspaceContentSummary {
            try await StaffWorkspaceContentCoordinator(dependencies: dependencies()).synchronize(source, published: published)
        }
    }

    @MainActor func assertPrepared(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await fixture.run()
        XCTAssertEqual(result.prepared, 1, file: file, line: line)
    }
    @MainActor func testActualServerSelectionDigestContentAndNativeBillingAgreeForAllFiveRoles() async throws {
        for role in AppUserRole.allCases {
            let f = try Fixture(role); defer { f.cleanup() }
            try f.row.selectionReceipt.verifyIndex(f.row.index)
            let result = try await f.run()
            XCTAssertEqual(result.prepared, 1); XCTAssertFalse(result.hasMore)
            XCTAssertEqual(try f.journal()?.lastReady, f.row.selectionRequest.operationID)
            XCTAssertNil(try f.journal()?.pending)
            XCTAssertEqual(f.calls.filter { $0.1 == "POST" }.count, 2)
            let before = f.calls.count, writes = f.writes
            try await assertPrepared(f)
            XCTAssertEqual(f.calls.count - before, 2)
            XCTAssertEqual(f.writes, writes)
            XCTAssertEqual(f.calls.filter { $0.1 == "POST" }.count, 2)
        }
    }
    @MainActor func testLostSelectionAndContentRepliesRecoverExactOriginalBytesAfterNewCoordinator() async throws {
        for selection in [true, false] {
            let f = try Fixture(); defer { f.cleanup() }
            f.lostSelection = selection; f.lostContent = !selection
            do { _ = try await f.run(); XCTFail("Expected interruption") } catch {}
            let original = try XCTUnwrap(f.journal()?.pending)
            try await assertPrepared(f)
            let requests = f.calls.filter { $0.1 == "POST" }
            for call in requests {
                XCTAssertEqual(call.2, call.0.hasSuffix("/full-selections") ? original.requestBytes : original.contentRequestBytes)
            }
        }
    }
    @MainActor func testEveryBeforeAndAfterDiskWriteFailureRetainsRecoverableOriginal() async throws {
        let baseline = try Fixture(); defer { baseline.cleanup() }
        _ = try await baseline.run()
        for write in 1...baseline.writes {
            for lostReply in [false, true] {
                let f = try Fixture(); defer { f.cleanup() }
                if lostReply { f.loseWrite = write } else { f.failWrite = write }
                do { _ = try await f.run(); XCTFail("Expected write interruption \(write)") } catch {}
                f.loseWrite = nil; f.failWrite = nil
                try await assertPrepared(f)
                XCTAssertNil(try f.journal()?.pending)
            }
        }
    }
    @MainActor func testIndexPaginationIsBoundedDurableAndResumesOriginalCursor() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.pageSize = 1
        let first = try await f.run()
        XCTAssertTrue(first.hasMore); XCTAssertEqual(first.prepared, 0)
        let pending = try XCTUnwrap(f.journal()?.pending)
        XCTAssertEqual(pending.index.count, 8); XCTAssertFalse(pending.indexComplete)
        XCTAssertFalse(f.calls.contains { $0.0.hasSuffix("/content") })
        f.pageSize = 100
        let count = f.calls.count
        try await assertPrepared(f)
        let page = try XCTUnwrap(f.calls.dropFirst(count).first { URLComponents(string: $0.0)?.path.hasSuffix("/records") == true })
        XCTAssertEqual(URLComponents(string: page.0)?.queryItems?.first { $0.name == "after" }?.value, pending.index.last?.key)
    }
    @MainActor func testPermissionLossAfterNetworkReplyStopsFurtherWritesAndRecoversLater() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.afterRequest = { _ in f.allowed = false }
        do { _ = try await f.run(); XCTFail("Expected access loss") } catch {}
        XCTAssertEqual(f.writes, 1); XCTAssertEqual(f.calls.count, 1)
        XCTAssertNil(try f.journal()?.pending?.selection)
        f.afterRequest = nil; f.allowed = true
        try await assertPrepared(f)
    }
    @MainActor func testSourceAdvanceKeepsOriginalReceiptAndCannotCommitOldReadyData() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.head = 2
        do { _ = try await f.run(); XCTFail("Expected newer source") } catch {}
        XCTAssertFalse(f.calls.contains { URLComponents(string: $0.0)?.path.hasSuffix("/chunks") == true })
        XCTAssertNil(try f.journal()?.lastReady); XCTAssertNil(try f.journal()?.pending)
        let key = StaffWorkspaceContentCoordinator.archiveKey(f.key, f.row.selectionRequest.operationID)
        let archive = try JSONDecoder().decode(StaffWorkspaceContentArchive.self, from: XCTUnwrap(f.saved[key]))
        XCTAssertEqual(archive.outcome, "sourceAdvanced"); XCTAssertEqual(archive.pending.selection?.currentSourceSequence, 2)
    }
    @MainActor func testCompletedArchiveIsNeverRewrittenWhenItsSourceAdvances() async throws {
        let f = try Fixture(); defer { f.cleanup() }; _ = try await f.run()
        let original = f.saved; f.head = 2
        do { _ = try await f.run(); XCTFail("Expected newer source") } catch {}
        XCTAssertEqual(f.saved, original)
    }
    @MainActor func testInterruptedChunkAndCorruptSavedChunkCannotSilentlyResetProgress() async throws {
        let f = try Fixture(); defer { f.cleanup() }; f.failChunk = true
        do { _ = try await f.run(); XCTFail("Expected interruption") } catch {}
        XCTAssertNotNil(try f.journal()?.pending?.content); XCTAssertEqual(try f.journal()?.pending?.offset, 0)
        f.failChunk = false; try await assertPrepared(f)
        let key = StaffWorkspaceContentCoordinator.chunkKey(f.key, f.row.selectionRequest.operationID, 0)
        let original = try XCTUnwrap(f.saved[key]); f.saved[key] = Data("damaged".utf8)
        let calls = f.calls.count
        do { _ = try await f.run(); XCTFail("Expected storage corruption") } catch {}
        XCTAssertEqual(f.saved[key], Data("damaged".utf8))
        XCTAssertFalse(f.calls.dropFirst(calls).contains { URLComponents(string: $0.0)?.path.hasSuffix("/chunks") == true })
        f.saved[key] = original; try await assertPrepared(f)
    }
    @MainActor func testForgedOrMissingIndexCannotReachContentPreparation() async throws {
        for kind in ["revision", "duplicate", "missing", "cursor"] {
            let f = try Fixture(); defer { f.cleanup() }
            f.mutateResponse = { path, bytes in
                guard URLComponents(string: path)?.path.hasSuffix("/records") == true else { return bytes }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                var rows = try XCTUnwrap(object["records"] as? [[String: Any]])
                switch kind {
                case "revision": rows[0]["revision"] = 99
                case "duplicate": rows.append(rows[0])
                case "missing": rows.removeLast()
                default: object["nextCursor"] = "customer:" + UUID().uuidString.lowercased()
                }
                object["records"] = rows
                return try JSONSerialization.data(withJSONObject: object)
            }
            do { _ = try await f.run(); XCTFail("Expected invalid index \(kind)") } catch {}
            XCTAssertFalse(f.calls.contains { $0.1 == "POST" && $0.0.hasSuffix("/content") })
        }
    }
    @MainActor func testBodyHeaderIdentityFieldCoverageAndOriginalScalarCannotBeForged() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try StaffWorkspaceContentVerification.validate(Data(f.row.payloadUtf8.utf8), receipt: f.row.contentReceipt, index: f.row.index,
            originals: f.vector.source, stage: f.stage, source: f.source, plan: f.plan,
            workspace: f.authority.cloud.base.workspace, now: f.now)
        for mutation in ["company", "identity", "scalar", "field", "branch"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(f.row.payloadUtf8.utf8)) as? [String: Any])
            var records = try XCTUnwrap(object["records"] as? [[String: Any]])
            let customer = try XCTUnwrap(records.firstIndex { $0["kind"] as? String == "customer" })
            if mutation == "company" { object["companyID"] = UUID().uuidString.lowercased() }
            else if mutation == "identity" { records[customer]["id"] = UUID().uuidString.lowercased() }
            else {
                var body = try XCTUnwrap(records[customer]["body"] as? [String: Any])
                if mutation == "branch" { body["billing"] = body.removeValue(forKey: "operational") }
                else {
                    var box = try XCTUnwrap(body["operational"] as? [String: Any])
                    var value = try XCTUnwrap(box["_0"] as? [String: Any])
                    var fields = try XCTUnwrap(value["fields"] as? [String: Any])
                    if mutation == "field" { fields.removeValue(forKey: "name") }
                    else { fields["name"] = ["text": ["_0": "Forged customer"]] }
                    value["fields"] = fields; box["_0"] = value; body["operational"] = box
                }
                records[customer]["body"] = body
            }
            object["records"] = records
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: f.modified(f.row.contentReceipt,
                ["payloadBytes": bytes.count, "contentSHA256": StaffReplicaManifest.hash(bytes)]))
            XCTAssertThrowsError(try StaffWorkspaceContentVerification.validate(bytes, receipt: receipt, index: f.row.index,
                originals: f.vector.source, stage: f.stage, source: f.source, plan: f.plan,
                workspace: f.authority.cloud.base.workspace, now: f.now), mutation)
        }
    }
    @MainActor func testFinalRemoteFencePreventsReadyPointerWhenSourceChangesAfterChunks() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.afterRequest = { path in if URLComponents(string: path)?.path.hasSuffix("/chunks") == true { f.head = 2 } }
        do { _ = try await f.run(); XCTFail("Expected final fence") } catch {}
        XCTAssertNil(try f.journal()?.lastReady)
        XCTAssertEqual(try f.journal()?.pending?.offset, f.row.contentReceipt.payloadBytes)
    }
    @MainActor func testActualEncryptedDiskStoreSurvivesNewCoordinatorWithoutPlaintextPayload() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let directory = f.authority.cloud.directory.appendingPathComponent("full-content", isDirectory: true)
        f.disk = .encrypted(directory: directory, maximumBytes: 40 * 1024 * 1024, key: { _ in Data(repeating: 63, count: 32) })
        f.lostContent = true
        do { _ = try await f.run(); XCTFail("Expected interruption") } catch {}
        try await assertPrepared(f)
        try await assertPrepared(f)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            XCTAssertFalse(text.contains("R-410A")); XCTAssertFalse(text.contains("Original sold valve"))
        }
    }
    @MainActor func testStrictOwnerRoutePolicyRejectsBroaderMethodsAndMalformedScope() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let request = f.row.selectionRequest, root = StaffWorkspaceContentHTTPPolicy.root(f.plan)
        let body = try StaffWorkspacePublicationContract.encode(request)
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: root, method: "POST", body: body))
        for suffix in ["", "/records", "/content", "/content/chunks", "/content/cloud-seal", "/content/cloud-key"] {
            let path = StaffWorkspaceContentHTTPPolicy.path(f.plan, request: request, suffix: suffix, offset: suffix.hasSuffix("chunks") ? 0 : nil)
            XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: path, method: "GET", body: nil))
            XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: "https://foreign.invalid" + path, method: "GET", body: nil))
            XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: path + "&companyID=" + request.companyID, method: "GET", body: nil))
            XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: path, method: "DELETE", body: nil))
        }
        let sealBody = try StaffWorkspacePublicationContract.encode(StaffWorkspaceContentRequest(request))
        let sealPost = root + "/" + request.operationID + "/content/cloud-seal"
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: sealPost, method: "POST", body: sealBody))
        let keyGet = StaffWorkspaceContentHTTPPolicy.path(f.plan, request: request, suffix: "/content/cloud-key")
        XCTAssertTrue(StaffWorkspaceContentHTTPPolicy.allows(path: keyGet, method: "GET", body: nil))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: keyGet, method: "POST", body: sealBody))
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: root + "?x=1", method: "POST", body: body))
        XCTAssertFalse(try StaffWorkspaceContentHTTPPolicy.allows(path: root, method: "POST", body: f.modified(request, ["role": "Admin"])))
        let chunk = StaffWorkspaceContentHTTPPolicy.path(f.plan, request: request, suffix: "/content/chunks", offset: 1)
        XCTAssertFalse(StaffWorkspaceContentHTTPPolicy.allows(path: chunk, method: "GET", body: nil))
    }

    @MainActor func testRealSourceCoordinatorPreparesFullContentAndRechecksSavedEditsBeforeCoreCapture() async throws {
        for editDuringContent in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }
            var stage = f.stage, fullSaved: [String: Data] = [:], coreSaved: [String: Data] = [:]
            var captures = 0
            if editDuringContent {
                f.afterRequest = { path in
                    guard path.contains("?"), URLComponents(string: path)?.path.hasSuffix("/content") == true else { return }
                    let records = stage.records.map { record -> StaffWorkspaceModelRecord in
                        guard record.kind == "customer" else { return record }
                        var fields = record.fields; fields["name"] = .text("Newer saved customer edit")
                        return .init(version: 1, kind: record.kind, id: record.id, fields: fields)
                    }
                    stage = .init(version: 1, scope: stage.scope, records: records, cursor: stage.cursor, deletionKeys: stage.deletionKeys)
                }
            }
            let publisher = StaffWorkspacePublicationCoordinator(dependencies: .init(check: f.dependencies().check,
                prepare: { _ in stage }, request: { path, method, _ in
                    XCTAssertEqual(method, "GET")
                    let query = Dictionary(uniqueKeysWithValues: (URLComponents(string: path)?.queryItems ?? []).map { ($0.name, $0.value!) })
                    let remaining = f.vector.source.filter { $0.key > (query["after"] ?? "") }
                    let page = Array(remaining.prefix(100))
                    return try StaffWorkspacePublicationContract.encode(StaffWorkspacePublicationPage(
                        companyID: f.row.selectionRequest.companyID, environment: "development", replicaID: f.row.selectionRequest.replicaID,
                        schema: StaffWorkspacePublicationContract.schema, schemaDigest: StaffWorkspacePublicationContract.schemaDigest,
                        sequence: 1, records: page, nextCursor: remaining.count > page.count ? page.last?.key : nil))
                }, store: .init(read: { fullSaved[$0] }, write: { fullSaved[$0] = $1 }), now: { f.now }))
            let dependencies = StaffReplicaSourceDependencies(context: { f.source }, check: f.dependencies().check,
                capture: { _, _ in
                    captures += 1
                    XCTAssertNotNil(try f.journal()?.lastReady)
                    return .init(source: .init(schema: StaffReplicaCoreSource.schemaVersion, coverage: StaffReplicaCoreSource.recordKinds, records: []), token: nil, deletions: [])
                }, request: { _, method, _ in
                    XCTAssertEqual(method, "GET")
                    return try JSONEncoder().encode(StaffReplicaSourcePage(schema: StaffReplicaCoreSource.schemaVersion,
                        companyID: f.source.scope.binding.companyID, environment: "development", replicaID: f.source.scope.binding.replicaID,
                        sequence: 0, authorizationSequence: 0, records: [], nextCursor: nil))
                }, store: .init(read: { coreSaved[$0] }, write: { coreSaved[$0] = $1 }), now: { f.now },
                fullWorkspace: publisher, fullContent: .init(dependencies: f.dependencies()))
            let coordinator = StaffReplicaSourceCoordinator(dependencies: dependencies)
            await coordinator.sync()
            XCTAssertNotNil(try f.journal()?.lastReady, coordinator.message)
            XCTAssertEqual(captures, editDuringContent ? 0 : 1, coordinator.message)
            XCTAssertEqual(coordinator.hasMore, editDuringContent, coordinator.message)
        }
    }
}
