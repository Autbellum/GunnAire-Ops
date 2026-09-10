import Foundation
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffWorkspaceFieldRefreshTests: XCTestCase {
    typealias Fixture = StaffWorkspaceFieldEditorTests.Fixture

    func installLargeWorkspace(_ f: Fixture, jobs: Int = 1000) throws -> Int {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(f.f.base.row.payloadUtf8.utf8)) as? [String: Any])
        var records = try XCTUnwrap(root["records"] as? [[String: Any]])
        let job = try XCTUnwrap(records.first { $0["kind"] as? String == "job" })
        for _ in 0..<jobs {
            var clone = job; clone["id"] = UUID().uuidString.lowercased(); records.append(clone)
        }
        root["records"] = records; root["sourceSequence"] = 2
        let raw = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])
        let receipt = try JSONDecoder().decode(StaffWorkspaceContentReceipt.self, from: f.f.base.modified(f.f.base.row.contentReceipt,
            ["selectionID": UUID().uuidString.lowercased(), "sourceSequence": 2, "currentSourceSequence": 2,
             "recordCount": records.count, "payloadBytes": raw.count, "contentSHA256": StaffReplicaManifest.hash(raw)]))
        let manifest = try StaffWorkspaceCloudSealManifest(content: receipt, sealedSHA256: String(repeating: "d", count: 64), sealedBytes: raw.count + 28)
        try StaffWorkspaceOperationalMountStore.install(opened: raw, manifest: manifest, store: f.f.memory.store,
            scope: f.context.scope, plan: f.plan.id, check: {})
        f.view = try StaffWorkspaceOperationalAcceptanceStore.accept(store: f.f.memory.store, scope: f.context.scope, plan: f.plan.id)
        return raw.count
    }

    func testUnchangedLifetimeRefreshDoesNotReadWholeWorkspace() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let payloadBytes = try installLargeWorkspace(f)
        let c = f.controller(); c.open(); c.setText("Retained draft")
        XCTAssertTrue(c.isEditing); XCTAssertFalse(c.hasUnprotectedChanges)
        var reads: [String] = []
        f.f.memory.onRead = { reads.append($0) }
        let started = Date()
        for _ in 0..<3 { c.checkLifetime() }
        let elapsed = Date().timeIntervalSince(started)
        f.f.memory.onRead = nil
        let payloadReads = reads.filter { $0.contains("\npayload") }.count
        print("STAFF_REFRESH_PROFILE records=\(f.view.records.count) payloadBytes=\(payloadBytes) ticks=3 payloadReads=\(payloadReads) totalReads=\(reads.count) milliseconds=\(elapsed * 1000)")
        XCTAssertEqual(payloadReads, 0, "Unchanged access refresh must not reparse the full workspace")
        XCTAssertEqual(reads.count, 9, "Three bounded metadata reads per tick")
        XCTAssertTrue(c.available); XCTAssertFalse(c.needsReview); XCTAssertEqual(c.input.text, "Retained draft")
    }

    func testChangedHeadIsFullyValidatedOnceInsteadOfEveryTick() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Original draft")
        let original = c.draft
        _ = try installLargeWorkspace(f, jobs: 0)
        var reads: [String] = []; f.f.memory.onRead = { reads.append($0) }
        for _ in 0..<3 { c.checkLifetime() }
        f.f.memory.onRead = nil
        XCTAssertEqual(reads.filter { $0.contains("\npayload") }.count, 1)
        XCTAssertTrue(c.needsReview); XCTAssertEqual(c.currentSnapshot?.sourceSequence, 2)
        XCTAssertEqual(c.draft, original); XCTAssertEqual(c.input.text, "Original draft")
        XCTAssertTrue(f.requests.isEmpty)
    }

    func testFailedChangedHeadDoesNotCauseATimerRetryStormAndExplicitRefreshRecovers() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Kept through unavailable content")
        let original = c.draft
        _ = try installLargeWorkspace(f, jobs: 0)
        let key = StaffWorkspaceOperationalMountStore.payloadKey(f.context.scope, f.plan.id, selection: f.view.selectionID)
        let originalBytes = try XCTUnwrap(f.f.memory.saved[key])
        f.f.memory.saved[key] = Data("damaged content".utf8)
        var reads: [String] = []; f.f.memory.onRead = { reads.append($0) }
        for _ in 0..<4 { c.checkLifetime() }
        f.f.memory.onRead = nil
        XCTAssertEqual(reads.filter { $0.contains("\npayload") }.count, 1)
        XCTAssertTrue(c.needsReview); XCTAssertNil(c.currentSnapshot); XCTAssertFalse(c.canSave)
        XCTAssertEqual(c.draft, original); XCTAssertTrue(c.available)
        f.f.memory.saved[key] = originalBytes
        c.checkLifetime(); XCTAssertNil(c.currentSnapshot)
        c.checkLifetime(forceRefresh: true)
        XCTAssertEqual(c.currentSnapshot?.sourceSequence, 2); XCTAssertTrue(c.needsReview)
        XCTAssertEqual(c.draft, original); XCTAssertTrue(f.requests.isEmpty)
    }

    func testFreshnessHintCannotAuthorizeSubmissionWithMissingOrCorruptPayload() async throws {
        for missing in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }
            let c = f.controller(); c.open(); c.setText("Only a draft")
            let snapshot = try XCTUnwrap(c.snapshot), original = c.draft
            let key = StaffWorkspaceOperationalMountStore.payloadKey(f.context.scope, f.plan.id)
            f.f.memory.saved[key] = missing ? nil : Data("corrupt payload".utf8)
            XCTAssertEqual(try f.engine.fieldEditorHead(snapshot, plan: f.plan, context: f.context), .init(snapshot: snapshot))
            await c.save()
            XCTAssertTrue(f.requests.isEmpty); XCTAssertTrue(c.saved.isEmpty); XCTAssertEqual(c.draft, original)
            c.checkLifetime(forceRefresh: true)
            XCTAssertNil(c.currentSnapshot); XCTAssertTrue(c.needsReview); XCTAssertFalse(c.canSave)
            XCTAssertThrowsError(try f.engine.fieldEditorSnapshot(plan: f.plan, context: f.context,
                selectionID: snapshot.selectionID, sourceSequence: snapshot.sourceSequence, contentSHA256: snapshot.contentSHA256,
                kind: snapshot.candidate.recordKind, recordID: snapshot.candidate.recordID,
                revision: snapshot.candidate.revision, field: snapshot.candidate.fieldName))
        }
    }

    func testMetadataAcceptanceMismatchPausesSubmissionWithoutLosingDraft() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Preserved across metadata mismatch")
        let original = c.draft
        let key = StaffWorkspaceOperationalAcceptanceStore.key(f.context.scope, f.plan.id)
        let bytes = try XCTUnwrap(f.f.memory.saved[key])
        let accepted = try JSONDecoder().decode(StaffWorkspaceOperationalAcceptance.self, from: bytes)
        f.f.memory.saved[key] = try f.f.base.modified(accepted, ["contentSHA256": String(repeating: "e", count: 64)])
        var reads: [String] = []; f.f.memory.onRead = { reads.append($0) }
        c.checkLifetime(); f.f.memory.onRead = nil
        XCTAssertFalse(reads.contains { $0.contains("\npayload") })
        XCTAssertTrue(c.needsReview); XCTAssertNil(c.currentSnapshot); XCTAssertFalse(c.canSave)
        XCTAssertEqual(c.draft, original); XCTAssertEqual(c.input.text, "Preserved across metadata mismatch")
        f.f.memory.saved[key] = bytes; c.checkLifetime()
        XCTAssertFalse(c.needsReview); XCTAssertTrue(c.canSave)
        XCTAssertTrue(c.message.contains("Continue your draft")); XCTAssertFalse(c.message.contains("not ready"))
    }

    func testMountChangingBetweenProbeReadsCannotPublishAFreshnessIdentity() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot()
        let meta = StaffWorkspaceOperationalMountStore.metaKey(f.context.scope, f.plan.id)
        let acceptance = StaffWorkspaceOperationalAcceptanceStore.key(f.context.scope, f.plan.id)
        let original = try XCTUnwrap(f.f.memory.saved[meta])
        f.f.memory.onRead = { key in if key == acceptance { f.f.memory.saved[meta] = Data("changed during read".utf8) } }
        XCTAssertThrowsError(try f.engine.fieldEditorHead(s, plan: f.plan, context: f.context))
        f.f.memory.onRead = nil; f.f.memory.saved[meta] = original
        XCTAssertEqual(try f.engine.fieldEditorHead(s, plan: f.plan, context: f.context), .init(snapshot: s))
    }

    func testRevocationDuringProbeClearsPrivateDisplayAndNeverWrites() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Private draft")
        let bytes = f.f.memory.saved, writes = f.f.memory.writes
        f.f.memory.onRead = { _ in f.f.allowed = false }
        c.checkLifetime(); f.f.memory.onRead = nil
        XCTAssertFalse(c.available); XCTAssertNil(c.snapshot); XCTAssertNil(c.draft); XCTAssertEqual(c.input.text, "")
        XCTAssertEqual(f.f.memory.saved, bytes); XCTAssertEqual(f.f.memory.writes, writes)
        f.f.allowed = true
        let next = f.controller(); next.open(); XCTAssertEqual(next.input.text, "Private draft")
    }

    func testForeignOrUnsupportedFieldProbeIsRejectedBeforeStorageReads() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot(), c = s.candidate
        let foreign = CloudKitStaffSetupScope(origin: s.scope.origin, company: UUID(), email: s.scope.email,
            environment: s.scope.environment, accountHash: s.scope.accountHash)
        let variants = [
            StaffWorkspaceFieldEditorSnapshot(scope: foreign, planID: s.planID, selectionID: s.selectionID,
                sourceSequence: s.sourceSequence, contentSHA256: s.contentSHA256, candidate: c),
            .init(scope: s.scope, planID: s.planID, selectionID: s.selectionID, sourceSequence: s.sourceSequence,
                contentSHA256: s.contentSHA256, candidate: .init(recordKind: c.recordKind, recordID: c.recordID,
                    revision: c.revision, fieldName: "total", currentValue: .number(1)))
        ]
        var reads = 0; f.f.memory.onRead = { _ in reads += 1 }
        for variant in variants { XCTAssertThrowsError(try f.engine.fieldEditorHead(variant, plan: f.plan, context: f.context)) }
        f.f.memory.onRead = nil; XCTAssertEqual(reads, 0)
    }

    func testMalformedMountMetadataFailsBothHintAndFullLoadWithoutRewritingEvidence() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let key = StaffWorkspaceOperationalMountStore.metaKey(f.context.scope, f.plan.id)
        let original = try XCTUnwrap(f.f.memory.saved[key])
        let mount = try JSONDecoder().decode(StaffWorkspaceOperationalMount.self, from: original)
        let bad: [(String, Any)] = [("selectionID", "../foreign"), ("sourceSequence", 0), ("contentSHA256", "bad"),
            ("sealedSHA256", "bad"), ("contentBytes", 0), ("contentBytes", StaffWorkspaceContentReceipt.maximumBytes + 1),
            ("storageSelectionID", UUID().uuidString.lowercased()), ("state", "unverified"), ("extra", true)]
        for (field, value) in bad {
            f.f.memory.saved[key] = try f.f.base.modified(mount, [field: value])
            let bytes = f.f.memory.saved
            XCTAssertThrowsError(try StaffWorkspaceOperationalMountStore.peekMetadata(store: f.f.memory.store, scope: f.context.scope, plan: f.plan.id), field)
            XCTAssertThrowsError(try StaffWorkspaceOperationalMountStore.load(store: f.f.memory.store, scope: f.context.scope, plan: f.plan.id), field)
            XCTAssertEqual(f.f.memory.saved, bytes)
        }
        f.f.memory.saved[key] = original
        XCTAssertNotNil(try StaffWorkspaceOperationalMountStore.load(store: f.f.memory.store, scope: f.context.scope, plan: f.plan.id))
    }

    func testMalformedAcceptanceMetadataIsNotRepairedIntoApparentSuccess() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let s = try f.snapshot(), key = StaffWorkspaceOperationalAcceptanceStore.key(f.context.scope, f.plan.id)
        let original = try XCTUnwrap(f.f.memory.saved[key])
        let accepted = try JSONDecoder().decode(StaffWorkspaceOperationalAcceptance.self, from: original)
        let bad: [(String, Any)] = [("recordCount", -1), ("recordCount", 20_001), ("sourceSequence", 0),
            ("selectionID", "../foreign"), ("contentSHA256", "bad"), ("extra", false)]
        for (field, value) in bad {
            f.f.memory.saved[key] = try f.f.base.modified(accepted, [field: value])
            let bytes = f.f.memory.saved
            XCTAssertThrowsError(try f.engine.fieldEditorHead(s, plan: f.plan, context: f.context), field)
            XCTAssertThrowsError(try f.engine.acceptMountedOperationalView(plan: f.plan, context: f.context), field)
            XCTAssertEqual(f.f.memory.saved, bytes)
        }
        f.f.memory.saved[key] = original
    }

    func testForceRefreshRevalidatesUnchangedPayloadAndNeverSubmits() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Review without submission")
        let original = c.draft
        var reads: [String] = []; f.f.memory.onRead = { reads.append($0) }
        c.checkLifetime(forceRefresh: true); f.f.memory.onRead = nil
        XCTAssertEqual(reads.filter { $0.contains("\npayload") }.count, 1)
        XCTAssertEqual(c.draft, original); XCTAssertFalse(c.needsReview); XCTAssertTrue(f.requests.isEmpty)
    }

    func testAccessRefreshRecoveryClearsStaleWarningAndRetainsDraft() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let c = f.controller(); c.open(); c.setText("Continue after refresh")
        let original = c.draft
        f.refreshing = true; c.checkLifetime()
        XCTAssertFalse(c.available); XCTAssertTrue(c.message.contains("refreshing"))
        XCTAssertEqual(c.draft, original); XCTAssertEqual(c.input.text, "Continue after refresh")
        f.refreshing = false; c.checkLifetime()
        XCTAssertTrue(c.available); XCTAssertTrue(c.canSave)
        XCTAssertTrue(c.message.contains("Continue your draft")); XCTAssertFalse(c.message.contains("refreshing"))
        XCTAssertEqual(c.draft, original); XCTAssertTrue(f.requests.isEmpty)
    }
}
