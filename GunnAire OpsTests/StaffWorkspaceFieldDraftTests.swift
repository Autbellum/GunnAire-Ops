import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceFieldDraftTests: XCTestCase {
    typealias Fixture = StaffWorkspaceFieldEditorTests.Fixture

    func advance(_ f: Fixture, sequence: Int = 2) throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(f.f.base.row.payloadUtf8.utf8)) as? [String: Any])
        root["sourceSequence"] = sequence
        var records = try XCTUnwrap(root["records"] as? [[String: Any]])
        let index = try XCTUnwrap(records.firstIndex { $0["kind"] as? String == "job" })
        var body = try XCTUnwrap(records[index]["body"] as? [String: Any])
        var branch = try XCTUnwrap(body["operational"] as? [String: Any])
        var partition = try XCTUnwrap(branch["_0"] as? [String: Any])
        var fields = try XCTUnwrap(partition["fields"] as? [String: Any])
        fields["notes"] = ["text": ["_0": "Updated office finding"]]
        partition["fields"] = fields; branch["_0"] = partition; body["operational"] = branch
        records[index]["body"] = body; records[index]["revision"] = sequence; root["records"] = records
        let raw = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        let receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: f.f.base.modified(f.f.base.row.contentReceipt,
            ["selectionID": UUID().uuidString.lowercased(), "sourceSequence": sequence, "currentSourceSequence": sequence,
             "payloadBytes": raw.count, "contentSHA256": StaffReplicaManifest.hash(raw)]))
        let manifest = try StaffWorkspaceCloudSealManifest(content: receipt, sealedSHA256: String(repeating: "c", count: 64), sealedBytes: raw.count + 28)
        try StaffWorkspaceOperationalMountStore.install(opened: raw, manifest: manifest, store: f.f.memory.store,
            scope: f.context.scope, plan: f.plan.id, check: {})
        f.view = try StaffWorkspaceOperationalAcceptanceStore.accept(store: f.f.memory.store, scope: f.context.scope, plan: f.plan.id)
    }

    func testTypingRestoresAfterRelaunchWithoutAnySubmissionOrNewID() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Pressure readings awaiting diagnosis")
        let original = try XCTUnwrap(c.draft)
        XCTAssertFalse(c.hasUnprotectedChanges); XCTAssertTrue(f.requests.isEmpty); XCTAssertTrue(c.saved.isEmpty)
        c.invalidate()
        let next = f.controller(); next.open()
        XCTAssertEqual(next.input.text, "Pressure readings awaiting diagnosis"); XCTAssertEqual(next.draft, original)
        XCTAssertEqual(f.operations, 1); XCTAssertTrue(next.isEditing); XCTAssertFalse(next.needsReview)
        XCTAssertTrue(try f.history(original.snapshot).isEmpty)
    }

    func testKeystrokesDoNotWalkCompletedSubmissionHistory() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open()
        var originals: [StaffWorkspaceOperationalCommandJournal] = []
        for n in 1...8 {
            c.setText("Completed finding \(n)"); await c.save()
            originals.append(try XCTUnwrap(c.saved.last))
            c.newUpdate()
        }
        let previousKeys = Set(originals.map { StaffWorkspaceOperationalCommandStore.key(f.context.scope, f.plan.id, commandID: $0.request.commandID) })
        var reads: [String] = []
        f.f.memory.onRead = { reads.append($0) }
        c.setText("Keep typing responsive")
        f.f.memory.onRead = nil
        XCTAssertFalse(c.hasUnprotectedChanges)
        XCTAssertTrue(previousKeys.isDisjoint(with: reads), "Autosave must not decrypt all completed receipts")
        XCTAssertLessThanOrEqual(reads.count, 8)
    }

    func testUnfinishedNumbersAndExplicitNullSurviveWithoutCoercion() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(field: "beforePhotoCount"); c.open(); c.setText("1.")
        XCTAssertTrue(c.isEditing); XCTAssertFalse(c.canSave); XCTAssertFalse(c.hasUnprotectedChanges)
        c.invalidate()
        let next = f.controller(field: "beforePhotoCount"); next.open()
        XCTAssertEqual(next.input.text, "1."); XCTAssertFalse(next.canSave)
        next.setText("3"); XCTAssertTrue(next.canSave)
        let text = f.controller(); text.open(); text.setText("Temporary finding"); text.clearValue(); text.invalidate()
        let restored = f.controller(); restored.open()
        XCTAssertTrue(restored.input.isNull); XCTAssertEqual(restored.input.text, "")
    }

    func testEveryInputControlPersistsRawState() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open()
        c.setText("Draft"); c.setFlag(true); c.setDate(Date(timeIntervalSinceReferenceDate: 100.25)); c.setNull(true)
        let raw = c.input
        c.invalidate(); let next = f.controller(); next.open()
        XCTAssertEqual(next.input, raw); XCTAssertFalse(next.hasUnprotectedChanges)
        XCTAssertTrue(f.requests.isEmpty)
    }

    func testBeforeAndAfterAutosaveWriteFailuresKeepNewestVerifiedDraft() throws {
        for after in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }
            let c = f.controller(); c.open(); c.setText("Previous verified text")
            let id = c.draft?.commandID
            if after { f.f.memory.failAfter = f.f.memory.writes + 1 } else { f.f.memory.failBefore = f.f.memory.writes + 1 }
            c.setText("Latest interrupted text")
            XCTAssertEqual(c.input.text, "Latest interrupted text")
            XCTAssertEqual(c.hasUnprotectedChanges, !after)
            f.f.memory.failAfter = nil; f.f.memory.failBefore = nil
            XCTAssertTrue(c.persistDraft()); XCTAssertEqual(c.draft?.commandID, id)
            c.invalidate(); let next = f.controller(); next.open()
            XCTAssertEqual(next.input.text, "Latest interrupted text"); XCTAssertEqual(next.draft?.commandID, id)
            XCTAssertTrue(f.requests.isEmpty)
        }
    }

    func testFailedInitialDraftWriteCanRecoverWithoutChangingIdentity() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.f.memory.failBefore = f.f.memory.writes + 1
        let c = f.controller(); c.open()
        XCTAssertTrue(c.isEditing); XCTAssertNil(c.draft)
        f.f.memory.failBefore = f.f.memory.writes + 1; c.setText("Keep me visible")
        XCTAssertTrue(c.hasUnprotectedChanges); XCTAssertEqual(c.input.text, "Keep me visible")
        f.f.memory.failBefore = nil; XCTAssertTrue(c.persistDraft())
        c.invalidate(); let next = f.controller(); next.open()
        XCTAssertEqual(next.input.text, "Keep me visible"); XCTAssertEqual(f.operations, 1)
    }

    func testTwoWindowsCannotOverwriteEachOtherOrSubmitStaleInput() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = f.controller(); a.open(); a.setText("Original draft")
        let b = f.controller(); b.open(); b.setText("Newer window finding")
        let latest = try XCTUnwrap(b.draft)
        a.setText("Stale window finding")
        XCTAssertTrue(a.hasUnprotectedChanges); XCTAssertFalse(a.discardDraft())
        await a.save(); XCTAssertTrue(f.requests.isEmpty)
        XCTAssertEqual(try f.engine.fieldEditorDraft(latest.snapshot, plan: f.plan, context: f.context), latest)
        XCTAssertEqual(a.input.text, "Stale window finding")
    }

    func testDiscardTombstonePreventsOldWindowResurrection() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = f.controller(); a.open(); a.setText("Discarded finding")
        let b = f.controller(); b.open(); let old = try XCTUnwrap(b.draft)
        XCTAssertTrue(a.discardDraft())
        b.setText("Late write from old window")
        XCTAssertTrue(b.hasUnprotectedChanges)
        let tombstone = try XCTUnwrap(f.engine.fieldEditorDraft(old.snapshot, plan: f.plan, context: f.context))
        XCTAssertNil(tombstone.input); XCTAssertEqual(tombstone.commandID, old.commandID)
        let next = f.controller(); next.open()
        XCTAssertNotEqual(next.draft?.commandID, old.commandID); XCTAssertEqual(next.input.text, "")
    }

    func testDiscardAcknowledgementLossIsRecoveredButFailedDiscardDoesNotClose() throws {
        for after in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }
            let c = f.controller(); c.open(); c.setText("Draft to discard explicitly")
            if after { f.f.memory.failAfter = f.f.memory.writes + 1 } else { f.f.memory.failBefore = f.f.memory.writes + 1 }
            XCTAssertEqual(c.discardDraft(), after)
            if !after { XCTAssertEqual(c.input.text, "Draft to discard explicitly") }
            f.f.memory.failAfter = nil; f.f.memory.failBefore = nil
            if !after { XCTAssertTrue(c.discardDraft()) }
            let next = f.controller(); next.open(); XCTAssertEqual(next.input.text, "")
        }
    }

    func testOfficeAdvanceRequiresExplicitReviewAndANewIntentBeforeSubmission() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Technician draft")
        let original = try XCTUnwrap(c.draft)
        try advance(f); c.checkLifetime()
        XCTAssertTrue(c.needsReview); XCTAssertFalse(c.canSave)
        c.setText("Technician draft with more detail") // Keep editing the frozen draft; do not rebase.
        XCTAssertEqual(c.draft?.snapshot, original.snapshot); XCTAssertFalse(c.hasUnprotectedChanges)
        c.invalidate(); let restored = f.controller(); restored.open()
        XCTAssertTrue(restored.needsReview); XCTAssertEqual(restored.input.text, "Technician draft with more detail")
        await restored.save(); XCTAssertTrue(f.requests.isEmpty)
        restored.useDraftWithCurrentRecord(reviewed: try XCTUnwrap(restored.currentSnapshot))
        XCTAssertFalse(restored.needsReview); XCTAssertNotEqual(restored.draft?.commandID, original.commandID)
        XCTAssertEqual(restored.snapshot?.candidate.revision, 2); XCTAssertEqual(restored.input.text, "Technician draft with more detail")
        XCTAssertTrue(f.requests.isEmpty)
        await restored.save()
        XCTAssertEqual(f.requests.count, 1); XCTAssertEqual(f.requests.first?.expectedRevision, 2)
        XCTAssertNotEqual(f.requests.first?.commandID, original.commandID.uuidString.lowercased())
    }

    func testUnreviewedSnapshotReplacementIsRejectedByCoordinator() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Frozen draft")
        let original = try XCTUnwrap(c.draft)
        try advance(f)
        let next = StaffWorkspaceFieldDraft(snapshot: try f.snapshot(), commandID: UUID(), revision: original.revision + 1,
            initial: .init(.text("Updated office finding")), input: original.input)
        let bytes = f.f.memory.saved
        XCTAssertThrowsError(try f.engine.saveFieldEditorDraft(next, expected: original, reviewing: false, plan: f.plan, context: f.context))
        XCTAssertEqual(f.f.memory.saved, bytes)
        let sameID = StaffWorkspaceFieldDraft(snapshot: next.snapshot, commandID: original.commandID,
            revision: next.revision, initial: original.initial, input: original.input)
        XCTAssertThrowsError(try f.engine.saveFieldEditorDraft(sameID, expected: original, reviewing: true, plan: f.plan, context: f.context))
    }

    func testASecondOfficeAdvanceCannotUseAnOlderReviewConfirmation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Original draft")
        try advance(f); c.checkLifetime()
        let shown = try XCTUnwrap(c.currentSnapshot), original = try XCTUnwrap(c.draft)
        try advance(f, sequence: 3)
        let bytes = f.f.memory.saved, operations = f.operations
        c.useDraftWithCurrentRecord(reviewed: shown)
        XCTAssertEqual(c.draft, original); XCTAssertEqual(f.f.memory.saved, bytes)
        XCTAssertEqual(f.operations, operations); XCTAssertTrue(c.needsReview); XCTAssertTrue(f.requests.isEmpty)
        c.checkLifetime()
        c.useDraftWithCurrentRecord(reviewed: try XCTUnwrap(c.currentSnapshot))
        XCTAssertEqual(c.snapshot?.sourceSequence, 3); XCTAssertFalse(c.needsReview)
    }

    func testQueuedOriginalLocksDraftAndRelaunchShowsSubmissionNotEditableDuplicate() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.offline = true
        let a = f.controller(); a.open(); a.setText("Original intent")
        let b = f.controller(); b.open()
        await a.save(); let original = try XCTUnwrap(a.saved.first)
        b.setText("Cannot replace an already queued intent"); XCTAssertTrue(b.hasUnprotectedChanges)
        await b.save(); XCTAssertEqual(f.requests, [original.request])
        let reopened = f.controller(); reopened.open()
        XCTAssertFalse(reopened.isEditing); XCTAssertEqual(reopened.saved.first?.request, original.request)
        f.offline = false; await reopened.retry(original)
        XCTAssertEqual(f.requests, [original.request, original.request]); XCTAssertEqual(f.operations, 1)
    }

    func testRevocationClearsDraftDisplayWithoutDeletingEncryptedOriginal() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Private technician draft")
        let bytes = f.f.memory.saved
        f.f.allowed = false; c.checkLifetime()
        XCTAssertEqual(c.input.text, ""); XCTAssertNil(c.draft); XCTAssertFalse(c.available)
        XCTAssertEqual(f.f.memory.saved, bytes)
        let denied = f.controller(); denied.open(); XCTAssertNil(denied.draft); XCTAssertEqual(f.f.memory.saved, bytes)
        f.f.allowed = true; let restored = f.controller(); restored.open()
        XCTAssertEqual(restored.input.text, "Private technician draft")
    }

    func testCorruptDraftFailsClosedWithoutOverwritingOrSubmitting() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Draft")
        let draft = try XCTUnwrap(c.draft), key = StaffWorkspaceFieldDraftStore.key(try f.snapshot())
        f.f.memory.saved[key] = Data("invalid draft".utf8)
        let bytes = f.f.memory.saved
        let next = f.controller(); next.open(); XCTAssertFalse(next.isEditing)
        c.setText("Do not overwrite evidence"); await c.save()
        XCTAssertEqual(f.f.memory.saved, bytes); XCTAssertTrue(f.requests.isEmpty)
        XCTAssertThrowsError(try f.queue(draft.snapshot, id: draft.commandID))
    }

    func testOversizedDraftIsVisibleButNeverFalselyReportedSaved() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Last valid draft")
        let previous = c.draft
        c.setText(String(repeating: "x", count: 65_537))
        XCTAssertTrue(c.hasUnprotectedChanges); XCTAssertEqual(c.draft, previous); XCTAssertFalse(c.canSave)
        c.invalidate(); let next = f.controller(); next.open(); XCTAssertEqual(next.input.text, "Last valid draft")
    }

    func testWrongScopeCannotLoadOrWriteDraftEvenWhenSnapshotBodyMatches() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Original scope")
        let d = try XCTUnwrap(c.draft), s = d.snapshot
        let foreign = CloudKitStaffSetupScope(origin: s.scope.origin, company: UUID(), email: s.scope.email,
            environment: s.scope.environment, accountHash: s.scope.accountHash)
        let snapshot = StaffWorkspaceFieldEditorSnapshot(scope: foreign, planID: s.planID, selectionID: s.selectionID,
            sourceSequence: s.sourceSequence, contentSHA256: s.contentSHA256, candidate: s.candidate)
        let next = StaffWorkspaceFieldDraft(snapshot: snapshot, commandID: UUID(), revision: 0, initial: d.initial, input: d.input)
        let bytes = f.f.memory.saved
        XCTAssertThrowsError(try f.engine.fieldEditorDraft(snapshot, plan: f.plan, context: f.context))
        XCTAssertThrowsError(try f.engine.saveFieldEditorDraft(next, expected: nil, reviewing: false, plan: f.plan, context: f.context))
        XCTAssertEqual(f.f.memory.saved, bytes)
    }

    func testDeviceDraftUsesEncryptedAuthenticatedStorageAndRestoresAfterStoreRecreation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StaffDraftTest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = Data(repeating: 42, count: 32)
        let disk = SharedTimeLocalStore.encrypted(directory: root, maximumBytes: 262_208, key: { _ in secret })
        let s = try f.snapshot()
        let draft = StaffWorkspaceFieldDraft(snapshot: s, commandID: UUID(), revision: 0,
            initial: .init(s.candidate.currentValue), input: .init(.text("Never store plaintext field findings")))
        try StaffWorkspaceFieldDraftStore.write(store: disk, next: draft, expected: nil, plan: f.plan, check: {})
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first), sealed = try Data(contentsOf: file)
        XCTAssertNil(sealed.range(of: Data("Never store plaintext field findings".utf8)))
        let reopened = SharedTimeLocalStore.encrypted(directory: root, maximumBytes: 262_208, key: { _ in secret })
        XCTAssertEqual(try StaffWorkspaceFieldDraftStore.load(store: reopened, snapshot: s, plan: f.plan), draft)
        let wrongKey = SharedTimeLocalStore.encrypted(directory: root, maximumBytes: 262_208, key: { _ in Data(repeating: 1, count: 32) })
        XCTAssertThrowsError(try StaffWorkspaceFieldDraftStore.load(store: wrongKey, snapshot: s, plan: f.plan))
        var corrupted = sealed; corrupted[corrupted.startIndex] ^= 1; try corrupted.write(to: file, options: .atomic)
        XCTAssertThrowsError(try StaffWorkspaceFieldDraftStore.load(store: reopened, snapshot: s, plan: f.plan))
    }
}
