import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceFieldEditorTests: XCTestCase {
    @MainActor final class Fixture {
        let f: StaffWorkspaceCommandRecoveryTests.Fixture
        let view: StaffWorkspaceOperationalView
        var offline = false
        var afterSend: (() -> Void)?
        var requests: [StaffWorkspaceOperationalCommandRequest] = []
        var operations = 0
        var plan: CloudKitStaffSharePlan { f.plan }
        var context: CloudKitStaffSetupController.Context { f.context }
        var engine: StaffWorkspaceContentCoordinator { .init(dependencies: f.dependencies()) }
        init() throws {
            f = try .init()
            let raw = Data(f.base.row.payloadUtf8.utf8)
            let manifest = try StaffWorkspaceCloudSealManifest(content: f.base.row.contentReceipt,
                sealedSHA256: String(repeating: "b", count: 64), sealedBytes: raw.count + 28)
            try StaffWorkspaceOperationalMountStore.install(opened: raw, manifest: manifest, store: f.memory.store,
                scope: f.context.scope, plan: f.plan.id, check: {})
            view = try StaffWorkspaceOperationalAcceptanceStore.accept(store: f.memory.store, scope: f.context.scope, plan: f.plan.id)
            f.transport = { [unowned self] _, bytes in
                let request = try StaffWorkspacePublicationContract.decode(StaffWorkspaceOperationalCommandRequest.self, from: bytes)
                requests.append(request)
                afterSend?()
                if offline { throw StaffReplicaDeliveryError.unavailable }
                return try StaffWorkspacePublicationContract.encode(f.receipt(for: request))
            }
        }
        func cleanup() { f.cleanup() }
        func snapshot(field: String = "notes") throws -> StaffWorkspaceFieldEditorSnapshot {
            let candidate = try XCTUnwrap(try StaffWorkspaceOperationalCommandStore.candidates(from: view)
                .first { $0.recordKind == "job" && $0.fieldName == field })
            return try engine.fieldEditorSnapshot(plan: plan, context: context, selectionID: view.selectionID,
                sourceSequence: view.sourceSequence, contentSHA256: view.contentSHA256, kind: candidate.recordKind,
                recordID: candidate.recordID, revision: candidate.revision, field: field)
        }
        func queue(_ snapshot: StaffWorkspaceFieldEditorSnapshot, id: UUID = UUID(), value: StaffWorkspaceValue = .text("Field finding")) throws -> StaffWorkspaceOperationalCommandJournal {
            try engine.queueFieldEditorUpdate(snapshot, plan: plan, context: context, commandID: id, value: value)
        }
        func history(_ snapshot: StaffWorkspaceFieldEditorSnapshot) throws -> [StaffWorkspaceOperationalCommandJournal] {
            try engine.fieldEditorHistory(snapshot, plan: plan, context: context)
        }
        func controller() -> StaffWorkspaceFieldEditorController {
            .init(dependencies: .init(authority: { [unowned self] in
                guard f.allowed else { throw StaffReplicaDeliveryError.access }
                return (context, plan)
            }, snapshot: { [unowned self] _, _ in try snapshot() },
            history: { [unowned self] snapshot, _, _ in try history(snapshot) },
            queue: { [unowned self] snapshot, _, _, id, value in try queue(snapshot, id: id, value: value) },
            send: { [unowned self] original, _, _ in try await engine.sendFieldEditorUpdate(original, plan: plan, context: context) },
            operation: { [unowned self] in operations += 1; return UUID() }))
        }
    }

    func testActualMountedFieldQueuesLocallyBeforeNetworkWithoutChangingSourceBytes() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let snapshot = try f.snapshot()
        let mountKey = StaffWorkspaceOperationalMountStore.payloadKey(f.context.scope, f.plan.id)
        let originalBytes = f.f.memory.saved[mountKey]
        let queued = try f.queue(snapshot)
        XCTAssertEqual(queued.state, "pending"); XCTAssertTrue(f.requests.isEmpty)
        XCTAssertEqual(try f.history(snapshot), [queued])
        let recorded = try await f.engine.sendFieldEditorUpdate(queued, plan: f.plan, context: f.context)
        XCTAssertEqual(recorded.state, "recorded")
        XCTAssertEqual(recorded.request, queued.request)
        XCTAssertEqual(recorded.receipt, f.f.receipt(for: queued.request))
        XCTAssertEqual(f.f.memory.saved[mountKey], originalBytes)
        XCTAssertEqual(try f.history(snapshot), [recorded])
        XCTAssertFalse(recorded.operationalWorkspaceReady)
    }
    func testStaleOrForgedDisplayedHeadCannotBeRebasedWhenSaving() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot(), c = s.candidate
        let variants = [
            StaffWorkspaceFieldEditorSnapshot(scope: s.scope, planID: s.planID, selectionID: UUID().uuidString.lowercased(),
                sourceSequence: s.sourceSequence, contentSHA256: s.contentSHA256, candidate: c),
            .init(scope: s.scope, planID: s.planID, selectionID: s.selectionID, sourceSequence: s.sourceSequence + 1,
                contentSHA256: s.contentSHA256, candidate: c),
            .init(scope: s.scope, planID: s.planID, selectionID: s.selectionID, sourceSequence: s.sourceSequence,
                contentSHA256: String(repeating: "a", count: 64), candidate: c),
            .init(scope: s.scope, planID: s.planID, selectionID: s.selectionID, sourceSequence: s.sourceSequence,
                contentSHA256: s.contentSHA256, candidate: .init(recordKind: c.recordKind, recordID: c.recordID,
                    revision: c.revision, fieldName: c.fieldName, currentValue: .text("Forged base")))
        ]
        for variant in variants { XCTAssertThrowsError(try f.queue(variant)) }
        XCTAssertTrue(try f.history(s).isEmpty); XCTAssertTrue(f.requests.isEmpty)
    }
    func testRestrictedAndFinancialFieldsCannotBecomeEditorSnapshots() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot()
        for field in ["status", "invoiceItemsJSON", "total", "customerID"] {
            XCTAssertThrowsError(try f.engine.fieldEditorSnapshot(plan: f.plan, context: f.context,
                selectionID: s.selectionID, sourceSequence: s.sourceSequence, contentSHA256: s.contentSHA256,
                kind: "job", recordID: s.candidate.recordID, revision: s.candidate.revision, field: field))
        }
    }
    func testEachInterruptedQueueWriteRecoversOneOriginalIncludingBackgroundReceiptRecovery() async throws {
        let baseline = try Fixture(); defer { baseline.cleanup() }
        let s = try baseline.snapshot()
        baseline.f.memory.writes = 0
        _ = try baseline.queue(s)
        let boundaries = baseline.f.memory.writes
        XCTAssertGreaterThanOrEqual(boundaries, 3)
        for boundary in 1...boundaries {
            for after in [false, true] {
                let f = try Fixture(); defer { f.cleanup() }
                let snapshot = try f.snapshot(), id = UUID()
                f.f.memory.writes = 0
                if after { f.f.memory.failAfter = boundary } else { f.f.memory.failBefore = boundary }
                XCTAssertThrowsError(try f.queue(snapshot, id: id), "boundary \(boundary), after=\(after)")
                f.f.memory.failBefore = nil; f.f.memory.failAfter = nil
                if try f.history(snapshot).isEmpty { _ = try f.queue(snapshot, id: id) }
                // Fresh coordinator; no UI identity or reference needs to survive.
                let recovered = try await f.engine.recoverOperationalCommands(plan: f.plan, context: f.context)
                XCTAssertEqual(recovered.pending, 0)
                let original = try XCTUnwrap(try f.history(snapshot).first)
                XCTAssertEqual(original.request.commandID, id.uuidString.lowercased())
                XCTAssertEqual(original.state, "recorded")
                XCTAssertEqual(Set(f.requests.map(\.commandID)), [id.uuidString.lowercased()])
            }
        }
    }
    func testLostReplyRetriesExactOriginalWithoutMountedSnapshot() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot(), queued = try f.queue(s)
        f.offline = true
        do { _ = try await f.engine.sendFieldEditorUpdate(queued, plan: f.plan, context: f.context); XCTFail("Lost reply") } catch {}
        f.f.memory.saved[StaffWorkspaceOperationalMountStore.metaKey(f.context.scope, f.plan.id)] = Data("unavailable head".utf8)
        f.offline = false
        let recorded = try await f.engine.sendFieldEditorUpdate(queued, plan: f.plan, context: f.context)
        XCTAssertEqual(f.requests, [queued.request, queued.request])
        XCTAssertEqual(recorded.receipt, f.f.receipt(for: queued.request))
        XCTAssertEqual(try f.history(s), [recorded])
    }
    func testRepeatedSaveCannotCreateDuplicateOrChangeOriginalIntent() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot(), id = UUID(), original = try f.queue(s, id: id)
        XCTAssertEqual(try f.queue(s, id: id), original)
        XCTAssertThrowsError(try f.queue(s, id: id, value: .text("Different intent")))
        XCTAssertThrowsError(try f.queue(s, value: .text("Another intent before receipt")))
        XCTAssertEqual(try f.history(s), [original])
    }
    func testRepeatedValueCanBeAnExplicitNewFindingAfterOfficeRevisionChanges() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot(), original = try f.queue(s)
        XCTAssertTrue(s.alreadySubmitted(original.request.value, history: [original]))
        let c = s.candidate
        let newer = StaffWorkspaceFieldEditorSnapshot(scope: s.scope, planID: s.planID, selectionID: s.selectionID,
            sourceSequence: s.sourceSequence + 1, contentSHA256: s.contentSHA256,
            candidate: .init(recordKind: c.recordKind, recordID: c.recordID, revision: c.revision + 1,
                             fieldName: c.fieldName, currentValue: .text("New office finding")))
        XCTAssertFalse(newer.alreadySubmitted(original.request.value, history: [original]))
    }
    func testTypingOptionalNoteSetsAValueAndClearingRemainsExplicit() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open()
        XCTAssertTrue(c.input.isNull)
        c.setText("Finding from site")
        XCTAssertFalse(c.input.isNull); XCTAssertTrue(c.canSave)
        c.clearValue()
        XCTAssertTrue(c.input.isNull); XCTAssertFalse(c.canSave, "Original optional note is already not set")
        c.setText("")
        XCTAssertFalse(c.input.isNull, "An explicit empty string is distinct from clearing an optional field")
    }
    func testSynchronousReleaseOfStaffCoordinatorsDoesNotHopExecutorsOrLeak() throws {
        let f = try Fixture(); defer { f.cleanup() }
        for _ in 0..<100 {
            weak var engine: StaffWorkspaceContentCoordinator?
            weak var editor: StaffWorkspaceFieldEditorController?
            weak var updates: StaffWorkspaceFieldUpdatesController?
            weak var receive: StaffReplicaReceiveController?
            autoreleasepool {
                let liveEngine = f.engine, liveEditor = f.controller()
                let liveUpdates = StaffWorkspaceFieldUpdatesController(dependencies: .init(
                    setup: { (f.context, [f.plan]) }, fetch: { _, _, _ in throw StaffReplicaDeliveryError.unavailable },
                    stamp: { f.context.stamp }, now: { f.f.base.now }))
                let liveReceive = StaffReplicaReceiveController(dependencies: .init(check: { _ in },
                    download: { _, _, _ in throw StaffReplicaDeliveryError.unavailable }, now: { f.f.base.now }))
                engine = liveEngine; editor = liveEditor; updates = liveUpdates; receive = liveReceive
                XCTAssertNotNil(engine); XCTAssertNotNil(editor); XCTAssertNotNil(updates); XCTAssertNotNil(receive)
            }
            XCTAssertNil(engine); XCTAssertNil(editor); XCTAssertNil(updates); XCTAssertNil(receive)
        }
    }
    func testUnknownOriginalCannotBeSentThroughEditorRetry() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot()
        let request = try s.request(plan: f.plan, commandID: UUID(), value: .text("Not queued"))
        let invented = try StaffWorkspaceOperationalCommandJournal(scope: f.context.scope, planID: f.plan.id, request: request)
        do { _ = try await f.engine.sendFieldEditorUpdate(invented, plan: f.plan, context: f.context); XCTFail("Unknown original") } catch {}
        XCTAssertTrue(f.requests.isEmpty); XCTAssertTrue(try f.history(s).isEmpty)
    }
    func testCorruptReferenceCannotBeOverwrittenOrDiscardOriginal() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot(), original = try f.queue(s), c = s.candidate
        let key = StaffWorkspaceFieldEditorStore.key(scope: s.scope, plan: s.planID, kind: c.recordKind, recordID: c.recordID, field: c.fieldName)
        f.f.memory.saved[key] = Data("damaged reference".utf8)
        let saved = f.f.memory.saved
        XCTAssertThrowsError(try f.history(s))
        XCTAssertThrowsError(try f.queue(s, id: UUID(uuidString: original.request.commandID)!))
        XCTAssertEqual(f.f.memory.saved, saved)
    }
    func testControllerOfflineSaveReopensAndRetriesWithoutGeneratingAnotherID() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.offline = true
        let first = f.controller(); first.open()
        XCTAssertTrue(first.isEditing)
        first.setText("Technician found a restricted filter")
        XCTAssertTrue(first.hasUnsavedChanges); XCTAssertTrue(first.canSave)
        await first.save()
        let original = try XCTUnwrap(first.saved.first)
        XCTAssertEqual(original.state, "pending"); XCTAssertFalse(first.isEditing)
        XCTAssertEqual(f.operations, 1)
        first.invalidate()
        let restarted = f.controller(); restarted.open()
        XCTAssertFalse(restarted.isEditing)
        XCTAssertEqual(restarted.saved.first?.request, original.request)
        XCTAssertEqual(f.operations, 1)
        f.offline = false
        await restarted.retry(original)
        XCTAssertEqual(restarted.saved.first?.state, "recorded")
        XCTAssertEqual(f.operations, 1)
        XCTAssertTrue(restarted.message.contains("office review"))
    }
    func testControllerKeepsUnsavedInputWhenNoDurableWriteSucceeded() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Unsaved field diagnosis")
        f.f.memory.failBefore = f.f.memory.writes + 1
        await c.save()
        XCTAssertEqual(c.input.text, "Unsaved field diagnosis")
        XCTAssertTrue(c.hasUnsavedChanges); XCTAssertTrue(c.saved.isEmpty); XCTAssertTrue(f.requests.isEmpty)
        f.f.memory.failBefore = nil
        await c.save()
        XCTAssertEqual(c.saved.first?.state, "recorded"); XCTAssertEqual(f.operations, 1)
    }
    func testControllerClearsDisplayOnRevocationButPreservesQueuedOriginal() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Retained private field finding")
        f.afterSend = { f.f.allowed = false }
        await c.save()
        XCTAssertFalse(c.available); XCTAssertTrue(c.saved.isEmpty); XCTAssertEqual(c.input.text, "")
        let requests = f.requests
        f.f.allowed = true
        let restarted = f.controller(); restarted.open()
        XCTAssertEqual(restarted.saved.first?.request, requests.first)
        XCTAssertEqual(restarted.saved.first?.state, "pending")
    }
    func testDismissalCannotRepopulatePrivateDisplayFromLateReply() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Field finding")
        f.afterSend = { c.invalidate() }
        await c.save()
        XCTAssertNil(c.snapshot); XCTAssertTrue(c.saved.isEmpty); XCTAssertEqual(c.input.text, "")
        XCTAssertFalse(c.isRunning)
    }
    func testNewUpdateRequiresExplicitActionAfterPriorReceiptAndRejectsSameValue() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("First finding"); await c.save()
        let first = try XCTUnwrap(c.saved.first)
        let restarted = f.controller(); restarted.open()
        XCTAssertFalse(restarted.isEditing); XCTAssertEqual(f.operations, 1)
        restarted.newUpdate()
        XCTAssertEqual(f.operations, 2); XCTAssertFalse(restarted.canSave)
        restarted.setText("Second explicit finding")
        await restarted.save()
        XCTAssertNotEqual(restarted.saved.last?.request.commandID, first.request.commandID)
        XCTAssertEqual(try StaffWorkspaceOperationalCommandStore.load(store: f.f.memory.store,
            scope: f.context.scope, plan: f.plan.id, commandID: first.request.commandID), first)
    }
    func testTypedInputsRejectInvalidNumbersNullsAndEnumValuesWithoutCoercion() throws {
        let integer = StaffWorkspaceFieldSchema(type: .integer, nullable: false, reference: nil, enumeration: nil)
        var input = StaffWorkspaceFieldEditorInput(.integer(1))
        input.text = "1.5"; XCTAssertThrowsError(try input.value(schema: integer))
        input.text = "two"; XCTAssertThrowsError(try input.value(schema: integer))
        input.text = "12"; XCTAssertEqual(try input.value(schema: integer), .integer(12))
        input.isNull = true; XCTAssertThrowsError(try input.value(schema: integer))
        let enumeration = StaffWorkspaceFieldSchema(type: .text, nullable: false, reference: nil, enumeration: ["Clear", "Needs service"])
        XCTAssertThrowsError(try StaffWorkspaceFieldEditorInput(.text("unknown")).value(schema: enumeration))
        let number = StaffWorkspaceFieldSchema(type: .number, nullable: false, reference: nil, enumeration: nil)
        XCTAssertThrowsError(try StaffWorkspaceFieldEditorInput(.text("nan")).value(schema: number))
        let flag = StaffWorkspaceFieldSchema(type: .flag, nullable: false, reference: nil, enumeration: nil)
        XCTAssertEqual(try StaffWorkspaceFieldEditorInput(.flag(true)).value(schema: flag), .flag(true))
        let date = StaffWorkspaceFieldSchema(type: .date, nullable: true, reference: nil, enumeration: nil)
        XCTAssertEqual(try StaffWorkspaceFieldEditorInput(.null).value(schema: date), .null)
    }

    func testLegacyPendingSiblingCannotStarveAnotherSavedUpdateOrLoseItsReceiptReference() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot()
        let bad = try f.queue(s, id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
        let goodRequest = try s.request(plan: f.plan, commandID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, value: .text("Another legacy finding"))
        try StaffWorkspaceOperationalCommandStore.enqueue(store: f.f.memory.store, scope: f.context.scope, plan: f.plan.id, request: goodRequest)
        f.f.transport = { _, bytes in
            let request = try StaffWorkspacePublicationContract.decode(StaffWorkspaceOperationalCommandRequest.self, from: bytes)
            if request.commandID == bad.request.commandID { throw StaffReplicaDeliveryError.unavailable }
            return try StaffWorkspacePublicationContract.encode(f.f.receipt(for: request))
        }
        let result = try await f.engine.recoverOperationalCommands(plan: f.plan, context: f.context)
        XCTAssertEqual(result, .init(recorded: 1, pending: 1))
        let history = try f.history(s)
        XCTAssertEqual(history.first?.request, bad.request)
        XCTAssertEqual(history.last?.request, goodRequest)
        XCTAssertEqual(history.last?.state, "recorded")
    }
    func testBoundedDiscoveryRetainsOriginalJournalsWhenOlderReferencesAreTrimmed() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot()
        var originals: [StaffWorkspaceOperationalCommandJournal] = []
        for n in 0..<129 {
            let request = try s.request(plan: f.plan, commandID: UUID(), value: .text("Finding \(n)"))
            try StaffWorkspaceOperationalCommandStore.enqueue(store: f.f.memory.store, scope: f.context.scope, plan: f.plan.id, request: request)
            let recorded = try StaffWorkspaceOperationalCommandStore.attachReceipt(store: f.f.memory.store, scope: f.context.scope,
                plan: f.plan.id, request: request, receipt: f.f.receipt(for: request))
            try StaffWorkspaceFieldEditorStore.remember(store: f.f.memory.store, scope: f.context.scope,
                plan: f.plan, original: recorded, check: {})
            originals.append(recorded)
        }
        let history = try f.history(s)
        XCTAssertEqual(history.count, 128)
        XCTAssertEqual(history.first, originals[1]); XCTAssertEqual(history.last, originals.last)
        XCTAssertEqual(try StaffWorkspaceOperationalCommandStore.load(store: f.f.memory.store, scope: f.context.scope,
            plan: f.plan.id, commandID: originals[0].request.commandID), originals[0])
    }
}
