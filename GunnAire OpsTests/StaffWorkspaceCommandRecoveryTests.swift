import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceCommandRecoveryTests: XCTestCase {
    @MainActor final class Fixture {
        let base: StaffWorkspaceContentCoordinatorTests.Fixture
        let context: CloudKitStaffSetupController.Context
        let request: StaffWorkspaceOperationalCommandRequest
        let memory = StaffWorkspaceRecoveryBoundaryTests.Memory()
        var allowed = true
        var transport: ((String, Data) async throws -> Data)?
        var plan: CloudKitStaffSharePlan { base.plan }
        init() throws {
            base = try .init()
            let b = base.authority.cloud.base
            context = .init(stamp: .init(session: .init(backendOrigin: "https://fixture.gunnaire.invalid",
                email: b.member.email, tokenFingerprint: String(repeating: "1", count: 64),
                expiresAt: b.now.addingTimeInterval(3600)), accountGeneration: UUID()), workspace: b.workspace,
                member: .init(email: b.member.email, role: base.plan.memberRole, isActive: true, createdAt: b.instant),
                account: .init(environment: base.plan.environment, accountHash: b.participantHash, recordName: b.participantName))
            let c = base.row.contentReceipt
            request = try .init(companyID: c.companyID, environment: c.environment, replicaID: c.replicaID,
                commandID: UUID(), selectionID: c.selectionID, sourceSequence: c.sourceSequence,
                contentSHA256: c.contentSHA256, candidate: .init(recordKind: "job", recordID: UUID().uuidString.lowercased(),
                    revision: 1, fieldName: "notes", currentValue: .text("Original office value")), value: .text("Original field finding"))
        }
        func cleanup() { base.cleanup() }
        func receipt(for request: StaffWorkspaceOperationalCommandRequest? = nil, actor: String? = nil,
                     instant: String = "2026-09-10T08:00:00Z") -> StaffWorkspaceOperationalCommandReceipt {
            let request = request ?? self.request
            return .init(schema: request.schema, commandID: request.commandID, selectionID: request.selectionID,
                sourceSequence: request.sourceSequence, contentSHA256: request.contentSHA256, recordKind: request.recordKind,
                recordID: request.recordID, expectedRevision: request.expectedRevision, fieldName: request.fieldName,
                value: request.value, actorEmail: actor ?? context.scope.email, createdAt: instant,
                state: "recorded", operationalWorkspaceReady: false)
        }
        func enqueue(_ request: StaffWorkspaceOperationalCommandRequest? = nil) throws {
            try StaffWorkspaceOperationalCommandStore.enqueue(store: memory.store, scope: context.scope,
                plan: plan.id, request: request ?? self.request)
        }
        func dependencies() -> StaffWorkspaceContentDependencies {
            var d = base.dependencies()
            d = .init(setup: d.setup, check: d.check, request: d.request, store: memory.store, now: d.now)
            d.operation = { XCTFail("Recovery must not create a new operation ID"); return UUID() }
            d.checkStaffSession = { [self] context in
                guard allowed, context.stamp == self.context.stamp else { throw StaffReplicaDeliveryError.access }
            }
            d.staffCommandRequest = { [self] path, bytes in
                guard let transport else { throw StaffReplicaDeliveryError.unavailable }
                return try await transport(path, bytes)
            }
            return d
        }
        func recover() async throws -> StaffWorkspaceCommandRecoverySummary {
            try await StaffWorkspaceContentCoordinator(dependencies: dependencies())
                .recoverOperationalCommands(plan: plan, context: context)
        }
    }

    func testEscapedUnicodeReceiptRecoversOriginalCommand() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let bytes = try f.base.modified(f.request, ["value": ["text": ["_0": String(repeating: "é", count: 3000)]]])
        let original = try JSONDecoder().decode(StaffWorkspaceOperationalCommandRequest.self, from: bytes)
        XCTAssertLessThan(bytes.count, 8192)
        try f.enqueue(original)
        f.transport = { _, sent in
            XCTAssertEqual(try JSONDecoder().decode(StaffWorkspaceOperationalCommandRequest.self, from: sent), original)
            let receipt = try StaffWorkspacePublicationContract.encode(f.receipt(for: original))
            let escaped = Data(String(decoding: receipt, as: UTF8.self).replacingOccurrences(of: "é", with: "\\u00e9").utf8)
            XCTAssertGreaterThan(escaped.count, 8192)
            return escaped
        }
        let result = try await f.recover()
        XCTAssertEqual(result.recorded, 1)
    }

    func testMalformedDecodedRequestsCannotEnterDurableQueue() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for (key, value) in [("commandID", "../foreign" as Any), ("sourceSequence", 0), ("expectedRevision", 0),
                             ("fieldName", "status"), ("value", ["flag": ["_0": true]]),
                             ("contentSHA256", "invalid"), ("schema", "unknown")] {
            let bytes = try f.base.modified(f.request, [key: value])
            let decoded = try JSONDecoder().decode(StaffWorkspaceOperationalCommandRequest.self, from: bytes)
            XCTAssertThrowsError(try f.enqueue(decoded), key)
            XCTAssertTrue(f.memory.saved.isEmpty, "Reject before persisting \(key)")
            f.memory.saved = [:]
        }
    }

    func testInvalidScalarValuesAreRejectedBeforeConstructingARequest() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for value in [StaffWorkspaceValue.flag(true), .text("unexpected\0value")] {
            XCTAssertThrowsError(try StaffWorkspaceOperationalCommandRequest(companyID: f.request.companyID,
                environment: f.request.environment, replicaID: f.request.replicaID, commandID: UUID(),
                selectionID: f.request.selectionID, sourceSequence: f.request.sourceSequence,
                contentSHA256: f.request.contentSHA256, candidate: .init(recordKind: "job", recordID: f.request.recordID,
                    revision: 1, fieldName: "notes", currentValue: .text("original")), value: value))
        }
    }

    func testReceiptCannotChangeOriginalAuthorOrUseUnparseableTimestamp() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.enqueue()
        let original = f.memory.saved
        for receipt in [f.receipt(actor: "foreign@example.invalid"), f.receipt(instant: "not-a-date")] {
            XCTAssertThrowsError(try StaffWorkspaceOperationalCommandStore.attachReceipt(store: f.memory.store,
                scope: f.context.scope, plan: f.plan.id, request: f.request, receipt: receipt))
            XCTAssertEqual(f.memory.saved, original)
        }
    }

    func testMediaHeadersRejectEmbeddedControlsAndInvalidMime() {
        for value in ["application/pdf\r\nX-Injected: yes", "x/", "x/y\0"] {
            XCTAssertFalse(StaffWorkspaceOperationalMediaGrant.validContentType(value))
        }
        for value in ["x\n.pdf", "x\r.pdf", "x\0.pdf", "x\u{7f}.pdf"] {
            XCTAssertFalse(StaffWorkspaceOperationalMediaGrant.validDisplayName(value))
            XCTAssertFalse(StaffWorkspaceOperationalMediaGrant.validDocumentID(value))
            XCTAssertFalse(StaffWorkspaceOperationalMediaGrant.validKindRaw(value))
        }
    }

    func testRestartRecoversOriginalWithoutAnyMountOrRebasedSelection() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.enqueue()
        var calls = 0
        f.transport = { path, bytes in
            calls += 1
            XCTAssertEqual(path, StaffWorkspaceContentHTTPPolicy.root(f.plan) + "/" + f.request.selectionID + "/content/commands")
            XCTAssertEqual(try StaffWorkspacePublicationContract.decode(StaffWorkspaceOperationalCommandRequest.self, from: bytes), f.request)
            return try StaffWorkspacePublicationContract.encode(f.receipt())
        }
        let summary = try await f.recover()
        XCTAssertEqual(summary, .init(recorded: 1, pending: 0))
        XCTAssertEqual(calls, 1)
        let repeated = try await StaffWorkspaceContentCoordinator(dependencies: f.dependencies()).submitOperationalCommand(
            plan: f.plan, context: f.context, recordKind: f.request.recordKind, recordID: f.request.recordID,
            fieldName: f.request.fieldName, value: f.request.value, commandID: UUID(uuidString: f.request.commandID))
        XCTAssertEqual(repeated.receipt, f.receipt())
        XCTAssertEqual(calls, 1)
        do {
            _ = try await StaffWorkspaceContentCoordinator(dependencies: f.dependencies()).submitOperationalCommand(
                plan: f.plan, context: f.context, recordKind: f.request.recordKind, recordID: f.request.recordID,
                fieldName: f.request.fieldName, value: .text("new intent"), commandID: UUID(uuidString: f.request.commandID))
            XCTFail("A new value cannot reuse the original identity")
        } catch {}
        XCTAssertEqual(calls, 1)
    }

    func testLostReplyAndInterruptedReceiptWritesRecoverAfterRestart() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.enqueue()
        let pending = f.memory.saved
        var lostReply = true, calls = 0
        f.transport = { _, bytes in
            calls += 1
            XCTAssertEqual(bytes, try StaffWorkspacePublicationContract.encode(f.request))
            if lostReply { throw StaffReplicaDeliveryError.unavailable }
            return try StaffWorkspacePublicationContract.encode(f.receipt())
        }
        let failed = try await f.recover()
        XCTAssertEqual(failed, .init(recorded: 0, pending: 1))
        XCTAssertEqual(f.memory.saved, pending)
        lostReply = false
        f.memory.writes = 0
        _ = try await f.recover()
        let boundaries = f.memory.writes
        for boundary in 1...boundaries {
            for after in [false, true] {
                f.memory.saved = pending; f.memory.writes = 0
                f.memory.failBefore = after ? nil : boundary
                f.memory.failAfter = after ? boundary : nil
                _ = try? await f.recover()
                f.memory.failBefore = nil; f.memory.failAfter = nil
                let restored = try await f.recover()
                XCTAssertEqual(restored.pending, 0)
                let journal = try StaffWorkspaceOperationalCommandStore.load(store: f.memory.store, scope: f.context.scope,
                    plan: f.plan.id, commandID: f.request.commandID)
                XCTAssertEqual(journal?.request, f.request)
                XCTAssertEqual(journal?.receipt, f.receipt())
            }
        }
        XCTAssertGreaterThan(calls, 1)
    }

    func testChangedAccountDuringReplyCannotAcknowledgeOriginal() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.enqueue()
        let pending = f.memory.saved
        f.transport = { _, _ in
            f.allowed = false
            return try StaffWorkspacePublicationContract.encode(f.receipt())
        }
        do { _ = try await f.recover(); XCTFail("Account change must escape fail-soft recovery") } catch {}
        XCTAssertEqual(f.memory.saved, pending)
        XCTAssertEqual(try StaffWorkspaceOperationalCommandStore.listPending(store: f.memory.store,
            scope: f.context.scope, plan: f.plan.id).count, 1)
    }

    func testRejectedOriginalDoesNotStarveAnotherReceiptRecovery() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.enqueue()
        let other = try JSONDecoder().decode(StaffWorkspaceOperationalCommandRequest.self,
            from: f.base.modified(f.request, ["commandID": UUID().uuidString.lowercased()]))
        try f.enqueue(other)
        var ids: [String] = []
        f.transport = { _, bytes in
            let request = try StaffWorkspacePublicationContract.decode(StaffWorkspaceOperationalCommandRequest.self, from: bytes)
            ids.append(request.commandID)
            if request == f.request { throw StaffReplicaSourceRejected(code: "source_changed") }
            return try StaffWorkspacePublicationContract.encode(f.receipt(for: request))
        }
        let summary = try await f.recover()
        XCTAssertEqual(summary, .init(recorded: 1, pending: 1))
        XCTAssertEqual(Set(ids), Set([f.request.commandID, other.commandID]))
        XCTAssertEqual(try StaffWorkspaceOperationalCommandStore.listPending(store: f.memory.store,
            scope: f.context.scope, plan: f.plan.id).map(\.request), [f.request])
    }

    func testHTTPValidLongFindingStillFitsRecordedJournal() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let request = try JSONDecoder().decode(StaffWorkspaceOperationalCommandRequest.self,
            from: f.base.modified(f.request, ["value": ["text": ["_0": String(repeating: "x", count: 6000)]]]))
        try f.enqueue(request)
        let receipt = f.receipt(for: request)
        XCTAssertLessThan(try StaffWorkspacePublicationContract.encode(receipt).count, 8192)
        let recorded = try StaffWorkspaceOperationalCommandStore.attachReceipt(store: f.memory.store,
            scope: f.context.scope, plan: f.plan.id, request: request, receipt: receipt)
        XCTAssertEqual(recorded.receipt, receipt)
    }

    func testCloudRefreshRunsCommandRecoveryEvenBeforeANewerMount() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.enqueue()
        f.transport = { _, _ in try StaffWorkspacePublicationContract.encode(f.receipt()) }
        var dependencies = f.dependencies()
        dependencies.participantCloudIO = { _, _, _, _ in throw StaffReplicaDeliveryError.unavailable }
        do {
            _ = try await StaffWorkspaceContentCoordinator(dependencies: dependencies).receiveAndLease(plan: f.plan,
                context: f.context, invitation: URL(string: "https://www.icloud.com/share/fixture-original-invitation")!)
            XCTFail("Cloud fixture intentionally remains unavailable")
        } catch {}
        XCTAssertTrue(try StaffWorkspaceOperationalCommandStore.listPending(store: f.memory.store,
            scope: f.context.scope, plan: f.plan.id).isEmpty)
        XCTAssertEqual(try StaffWorkspaceOperationalCommandStore.load(store: f.memory.store, scope: f.context.scope,
            plan: f.plan.id, commandID: f.request.commandID)?.receipt, f.receipt())
    }

    func testNullableFieldCanStillBeExplicitlyCleared() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let request = try JSONDecoder().decode(StaffWorkspaceOperationalCommandRequest.self,
            from: f.base.modified(f.request, ["value": ["null": [:]]]))
        XCTAssertNoThrow(try f.enqueue(request))
    }

    func testBoundedPassRotatesPastBlockedFirstPageAfterRestart() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        var commands: [StaffWorkspaceOperationalCommandRequest] = []
        for n in 1...3 {
            let request = try JSONDecoder().decode(StaffWorkspaceOperationalCommandRequest.self, from: f.base.modified(f.request,
                ["commandID": String(format: "af000000-0000-4000-8000-%012d", n)]))
            try f.enqueue(request); commands.append(request)
        }
        var visited: [String] = []
        f.transport = { _, bytes in
            let request = try StaffWorkspacePublicationContract.decode(StaffWorkspaceOperationalCommandRequest.self, from: bytes)
            visited.append(request.commandID)
            throw StaffReplicaDeliveryError.unavailable
        }
        for _ in 0..<2 {
            let result = try await StaffWorkspaceContentCoordinator(dependencies: f.dependencies())
                .recoverOperationalCommands(plan: f.plan, context: f.context, maximum: 2)
            XCTAssertEqual(result, .init(recorded: 0, pending: 3))
        }
        XCTAssertEqual(visited, [commands[0], commands[1], commands[2], commands[0]].map(\.commandID))
        XCTAssertEqual(try StaffWorkspaceOperationalCommandStore.listPending(store: f.memory.store,
            scope: f.context.scope, plan: f.plan.id).map(\.request), commands)
    }

    func testFullReceiveFallbackCannotKeepCoreAfterAuthorityChanges() async throws {
        let f = try StaffReplicaReceiveTests.Fixture(); defer { f.cleanup() }
        var dependencies = f.controller().dependencies
        dependencies.receiveFullWorkspace = { _, _, _ in
            f.cloud.authorized = false
            throw StaffReplicaDeliveryError.unavailable
        }
        let controller = StaffReplicaReceiveController(dependencies: dependencies)
        try await f.receive(controller)
        XCTAssertNil(controller.received)
        XCTAssertNil(controller.hostedStore)
        XCTAssertNil(controller.operationalIdentity)
        XCTAssertFalse(controller.message.hasPrefix("Core records received"))
    }
}
