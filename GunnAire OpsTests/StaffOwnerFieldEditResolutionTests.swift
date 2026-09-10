import Foundation
import SwiftData
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffOwnerFieldEditResolutionTests: XCTestCase {
    typealias Fixture = StaffOwnerFieldEditTests.Fixture
    func conflict(_ f: Fixture) async throws -> (StaffOwnerFieldEditCoordinator, StaffOwnerFieldEditReview) {
        try f.officeChange("Office value to keep"); try f.publishSaved()
        let coordinator = f.coordinator(); try await coordinator.synchronize(f.source)
        return (coordinator, try XCTUnwrap(coordinator.reviews.first))
    }
    func archive(_ f: Fixture, operation: String) throws -> StaffOwnerFieldEditKeepArchive {
        let key = StaffOwnerFieldEditCoordinator.keepArchiveKey(f.source.scope, operationID: operation)
        let value = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldEditKeepArchive.self,
            from: XCTUnwrap(f.memory.saved[key]), maximum: 64 * 1024 * 1024)
        try value.validate(f.source.scope)
        return value
    }

    func testKeepOfficeClosesUnclaimedEditWithoutWritingARecord() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (coordinator, review) = try await conflict(f)
        XCTAssertTrue(review.canKeepOffice)
        try await coordinator.keepOffice(review, context: f.source)
        XCTAssertEqual(try f.savedValue(), .text("Office value to keep"))
        XCTAssertEqual(f.applyCalls, 0)
        XCTAssertTrue(try f.journal().keepOffice?.isEmpty == true)
        let original = try XCTUnwrap(f.keepRequests.first)
        let saved = try archive(f, operation: original.operationID)
        XCTAssertEqual(saved.pending.edit.receipt, f.receipt)
        XCTAssertEqual(saved.resolution?.request, original)
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(f.applyCalls, 0)
    }

    func testPreparedThirdValueConflictKeepsOriginalClaimAndOfficeRecord() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.losePrepare = true; try await f.coordinator().synchronize(f.source)
        let claim = try XCTUnwrap(f.application)
        let (coordinator, review) = try await conflict(f)
        XCTAssertFalse(review.canApplyReviewed); XCTAssertTrue(review.canKeepOffice)
        try await coordinator.keepOffice(review, context: f.source)
        XCTAssertEqual(f.application, claim)
        XCTAssertEqual(f.resolution?.request.claimOperationID, claim.operationID)
        XCTAssertTrue(try f.journal().pending.isEmpty)
        let saved = try archive(f, operation: XCTUnwrap(f.resolution?.request.operationID))
        XCTAssertEqual(saved.applicationIntent?.request.operationID, claim.operationID)
        XCTAssertEqual(saved.pending.edit.receipt, f.receipt)
        XCTAssertEqual(try f.savedValue(), .text("Office value to keep"))
        XCTAssertEqual(f.applyCalls, 0)
    }

    func testEveryDecisionWriteBoundaryRecoversWithoutApplyingTheField() async throws {
        let baseline = try Fixture(); defer { baseline.cleanup() }
        let (coordinator, review) = try await conflict(baseline)
        let start = baseline.memory.writes
        try await coordinator.keepOffice(review, context: baseline.source)
        let boundaries = baseline.memory.writes - start
        XCTAssertEqual(boundaries, 3)
        for boundary in 1...boundaries {
            for after in [false, true] {
                let f = try Fixture(); defer { f.cleanup() }
                let (coordinator, review) = try await conflict(f)
                if after { f.memory.failAfter = f.memory.writes + boundary } else { f.memory.failBefore = f.memory.writes + boundary }
                do { try await coordinator.keepOffice(review, context: f.source) } catch {}
                f.memory.failBefore = nil; f.memory.failAfter = nil
                let restarted = f.coordinator(); try await restarted.synchronize(f.source)
                if f.resolution == nil {
                    XCTAssertTrue(f.keepRequests.isEmpty, "Only an intent that failed before durability needs a new explicit decision")
                    try await restarted.keepOffice(XCTUnwrap(restarted.reviews.first), context: f.source)
                }
                XCTAssertEqual(try f.savedValue(), .text("Office value to keep"))
                XCTAssertEqual(f.applyCalls, 0)
                XCTAssertTrue(try f.journal().keepOffice?.isEmpty == true)
                XCTAssertEqual(Set(f.keepRequests.map(\.operationID)).count, 1)
                XCTAssertEqual(try archive(f, operation: XCTUnwrap(f.resolution?.request.operationID)).pending.edit.receipt, f.receipt)
            }
        }
    }

    func testLostReplyPreservesOriginalDecisionAndNewerOfficeDraft() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (coordinator, review) = try await conflict(f)
        f.loseKeep = true
        do { try await coordinator.keepOffice(review, context: f.source); XCTFail("Lost reply") } catch {}
        let original = try XCTUnwrap(f.resolution)
        f.job.notes = "A newer unsaved office draft"
        try await f.coordinator().synchronize(f.source)
        XCTAssertEqual(f.job.notes, "A newer unsaved office draft")
        XCTAssertTrue(f.container.mainContext.hasChanges)
        XCTAssertEqual(f.resolution, original)
        XCTAssertEqual(f.applyCalls, 0)
        XCTAssertTrue(try f.journal().keepOffice?.isEmpty == true)
    }

    func testStaleDecisionIsArchivedBeforeFreshReviewCreatesAnotherIdentity() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (coordinator, review) = try await conflict(f)
        f.beforeKeep = { try f.officeChange("Newer office value"); try f.publishSaved() }
        do { try await coordinator.keepOffice(review, context: f.source); XCTFail("Stale decision") } catch {}
        let old = try XCTUnwrap(f.keepRequests.first)
        XCTAssertNil(f.resolution)
        f.beforeKeep = nil
        let restarted = f.coordinator(); try await restarted.synchronize(f.source)
        let fresh = try XCTUnwrap(restarted.reviews.first)
        XCTAssertFalse(fresh.canApplyReviewed)
        try await restarted.keepOffice(fresh, context: f.source)
        XCTAssertEqual(Set(f.keepRequests.map(\.operationID)).count, 2)
        XCTAssertEqual(try archive(f, operation: old.operationID).supersededAtRevision, f.serverRevision)
        XCTAssertEqual(try f.savedValue(), .text("Newer office value"))
        XCTAssertEqual(f.applyCalls, 0)
    }

    func testConcurrentClaimNeedsFreshReviewAndRetainsTheSupersededDecision() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (coordinator, review) = try await conflict(f)
        let claimID = UUID().uuidString.lowercased()
        f.beforeKeep = {
            f.application = .init(schema: StaffOwnerFieldEdit.schema, commandID: f.original.commandID,
                operationID: claimID, ownerStoreID: f.source.scope.storeUUID.lowercased(), ownerEmail: f.source.scope.actorEmail,
                preparedAt: "2026-09-10T08:01:00Z", expectedRevision: f.serverRevision,
                expectedValue: f.serverValue, reviewedConflict: true, state: "prepared", publishedAt: nil)
        }
        do { try await coordinator.keepOffice(review, context: f.source); XCTFail("Claim changed") } catch {}
        let old = try XCTUnwrap(f.keepRequests.first); f.beforeKeep = nil
        let restarted = f.coordinator(); try await restarted.synchronize(f.source)
        try await restarted.keepOffice(XCTUnwrap(restarted.reviews.first), context: f.source)
        XCTAssertEqual(try archive(f, operation: old.operationID).supersededByClaim, claimID)
        XCTAssertEqual(f.resolution?.request.claimOperationID, claimID)
        XCTAssertEqual(f.applyCalls, 0)
    }

    func testOlderJournalRestoreRecoversExactServerDecisionWithoutNewIdentity() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.losePrepare = true; try await f.coordinator().synchronize(f.source)
        let key = StaffOwnerFieldEditCoordinator.key(f.source.scope)
        let oldJournal = try XCTUnwrap(f.memory.saved[key])
        let (coordinator, review) = try await conflict(f)
        try await coordinator.keepOffice(review, context: f.source)
        let receipt = try XCTUnwrap(f.resolution)
        let archiveKey = StaffOwnerFieldEditCoordinator.keepArchiveKey(f.source.scope, operationID: receipt.request.operationID)
        let originalArchive = f.memory.saved[archiveKey]
        f.memory.saved[key] = oldJournal
        try f.officeChange("Office correction after resolution"); try f.publishSaved()
        try await f.coordinator().synchronize(f.source)
        XCTAssertTrue(try f.journal().pending.isEmpty)
        XCTAssertEqual(f.keepRequests.count, 1)
        XCTAssertEqual(f.memory.saved[archiveKey], originalArchive)
        XCTAssertEqual(try f.savedValue(), .text("Office correction after resolution"))
        XCTAssertEqual(f.applyCalls, 0)
    }

    func testAccountChangeAfterDecisionReplyRetainsRecoveryAndNeverWritesModel() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (coordinator, review) = try await conflict(f)
        f.beforeKeep = { f.afterResponse = { f.allowed = false } }
        do { try await coordinator.keepOffice(review, context: f.source); XCTFail("Authority changed") } catch {}
        XCTAssertNotNil(f.resolution)
        XCTAssertFalse(try f.journal().keepOffice?.isEmpty ?? true)
        XCTAssertEqual(f.applyCalls, 0)
        f.allowed = true; f.afterResponse = nil; f.beforeKeep = nil
        try await f.coordinator().synchronize(f.source)
        XCTAssertTrue(try f.journal().keepOffice?.isEmpty == true)
    }

    func testBacklogDrainsPastEightAndPropagatesToOwnerSync() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let core = StaffReplicaSourceSyncTests.Fixture()
        let ids = (0..<50).map { _ in UUID().uuidString.lowercased() }.sorted()
        let memory = StaffWorkspaceRecoveryBoundaryTests.Memory()
        var visited: [String] = []
        f.serverValue = .text("Office value to keep"); f.serverRevision = 2
        let worker = StaffOwnerFieldEditCoordinator(dependencies: .init(check: { _ in }, request: { path, method, _ in
            XCTAssertEqual(method, "GET")
            let url = try XCTUnwrap(URLComponents(string: path))
            if url.path == StaffOwnerFieldEditTransport.root {
                let first = !(url.queryItems ?? []).contains { $0.name == "after" }
                return try StaffWorkspacePublicationContract.encode(StaffOwnerFieldEditPage(schema: StaffOwnerFieldEdit.schema,
                    companyID: core.binding.companyID.uuidString.lowercased(), environment: core.binding.environment,
                    replicaID: core.binding.replicaID.uuidString.lowercased(), commandIDs: first ? ids : [], nextCursor: first ? ids.last : nil))
            }
            let id = String(url.path.split(separator: "/").last!); visited.append(id)
            var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(f.edit)) as? [String: Any])
            var request = try XCTUnwrap(entry["request"] as? [String: Any]); request["commandID"] = id
            request["companyID"] = core.binding.companyID.uuidString.lowercased(); request["replicaID"] = core.binding.replicaID.uuidString.lowercased()
            var receipt = try XCTUnwrap(entry["receipt"] as? [String: Any]); receipt["commandID"] = id
            entry["request"] = request; entry["receipt"] = receipt
            return try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        }, store: memory.store, read: { _, _ in .text("Office value to keep") }, apply: { _, _, _ in XCTFail("Conflicted backlog must never auto-apply") }))
        var dependencies = core.dependencies(); dependencies.ownerFieldEdits = worker
        let source = StaffReplicaSourceCoordinator(dependencies: dependencies)
        await source.sync()
        XCTAssertEqual(visited.count, 8); XCTAssertTrue(source.hasMore)
        XCTAssertEqual(source.message, "Checking more field updates…")
        for _ in 0..<7 { await source.sync() }
        XCTAssertEqual(visited, ids)
        XCTAssertFalse(worker.hasMore); XCTAssertFalse(source.hasMore)
    }

    func testCorruptDecisionArchiveCannotBeOverwrittenOrMistakenForRecovery() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let (coordinator, review) = try await conflict(f)
        f.loseKeep = true
        do { try await coordinator.keepOffice(review, context: f.source) } catch {}
        let receipt = try XCTUnwrap(f.resolution)
        let key = StaffOwnerFieldEditCoordinator.keepArchiveKey(f.source.scope, operationID: receipt.request.operationID)
        let damaged = Data("damaged original decision archive".utf8); f.memory.saved[key] = damaged
        let recovered = f.coordinator(); try await recovered.synchronize(f.source)
        XCTAssertEqual(f.memory.saved[key], damaged)
        XCTAssertFalse(try f.journal().keepOffice?.isEmpty ?? true)
        XCTAssertEqual(try f.savedValue(), .text("Office value to keep"))
        XCTAssertEqual(f.applyCalls, 0)
        XCTAssertFalse(recovered.reviews.isEmpty)
    }
}
