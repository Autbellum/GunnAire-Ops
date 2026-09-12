import Foundation
import SwiftData
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffOwnerFieldHandoffTests: XCTestCase {
    @MainActor final class Fixture {
        let base: StaffOwnerFieldEditTests.Fixture
        var receipt: StaffOwnerFieldHandoffReceipt?
        var releases: [StaffOwnerFieldHandoffRequest] = []
        var loseRelease = false
        var beforeRelease: (() throws -> Void)?
        var afterRelease: (() -> Void)?
        init() throws { base = try .init() }
        var fenceKey: String { StaffOwnerFieldHandoffFence.key(base.source.scope, id: base.original.commandID) }
        func coordinator() -> StaffOwnerFieldEditCoordinator {
            let original = base.coordinator().dependencies
            return .init(dependencies: .init(check: original.check, request: { path, method, body in
                guard path.hasSuffix("/release") else { return try await original.request(path, method, body) }
                let request = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldHandoffRequest.self, from: XCTUnwrap(body))
                XCTAssertTrue(StaffOwnerFieldEditTransport.allows(path: path, method: method, body: body))
                let fence = try XCTUnwrap(StaffOwnerFieldHandoffFence.load(self.base.source.scope, id: self.base.original.commandID, store: self.base.memory.store))
                XCTAssertEqual(fence.request, request, "The complete stop-write fence must precede the request")
                self.releases.append(request); try self.beforeRelease?()
                if let receipt = self.receipt { XCTAssertEqual(receipt.request, request) }
                else {
                    guard self.base.application?.operationID == request.claimOperationID,
                          self.base.serverRevision == request.expectedRevision, self.base.serverValue == request.expectedValue
                    else { throw StaffReplicaSourceRejected(code: "field_changed") }
                    self.receipt = .init(schema: request.schema, request: request, ownerEmail: self.base.source.scope.actorEmail,
                        releasedAt: "2026-09-10T08:04:00Z", outcome: "released")
                    self.base.application = nil
                }
                self.afterRelease?()
                if self.loseRelease { self.loseRelease = false; throw StaffReplicaSourceSyncError.unavailable }
                return try StaffWorkspacePublicationContract.encode(XCTUnwrap(self.receipt))
            }, store: original.store, read: original.read, apply: { edit, expected, context in
                try StaffOwnerFieldHandoffFence.checkWrite(context.scope, id: edit.id, store: original.store)
                try original.apply(edit, expected, context)
            }))
        }
        func paused() async throws -> (StaffOwnerFieldEditCoordinator, StaffOwnerFieldEditReview) {
            base.losePrepare = true
            let coordinator = coordinator()
            try await coordinator.synchronize(base.source)
            XCTAssertEqual(base.applyCalls, 0)
            let review = try XCTUnwrap(coordinator.reviews.first)
            XCTAssertTrue(review.canRelease)
            return (coordinator, review)
        }
    }

    func testActualSavedStoreIsUnchangedAndOriginalDeviceNeverReappliesAfterHandoff() async throws {
        let f = try Fixture(); defer { f.base.cleanup() }
        let (coordinator, review) = try await f.paused()
        let before = try f.base.savedValue()
        try await coordinator.release(review, context: f.base.source)
        let fenceBytes = try XCTUnwrap(f.base.memory.saved[f.fenceKey])
        XCTAssertNotNil(f.receipt)
        XCTAssertTrue(try f.base.journal().pending.isEmpty)
        for _ in 0..<3 { try await f.coordinator().synchronize(f.base.source) }
        XCTAssertEqual(try f.base.savedValue(), before)
        XCTAssertEqual(f.base.applyCalls, 0)
        XCTAssertEqual(f.releases.count, 1)
        XCTAssertEqual(f.base.prepareRequests.count, 1)
        XCTAssertEqual(f.base.memory.saved[f.fenceKey], fenceBytes)
        // A reconstructed queue cannot remove the independent write fence.
        f.base.memory.saved.removeValue(forKey: StaffOwnerFieldEditCoordinator.key(f.base.source.scope))
        try await f.coordinator().synchronize(f.base.source)
        XCTAssertEqual(f.base.applyCalls, 0)
        XCTAssertEqual(f.base.memory.saved[f.fenceKey], fenceBytes)
    }

    func testLostReleaseReplyRecoversOriginalAfterAnotherDeviceClaims() async throws {
        let f = try Fixture(); defer { f.base.cleanup() }
        let (coordinator, review) = try await f.paused()
        f.loseRelease = true
        do { try await coordinator.release(review, context: f.base.source); XCTFail() } catch {}
        let claim = try XCTUnwrap(review.edit.application)
        f.base.application = .init(schema: claim.schema, commandID: claim.commandID, operationID: UUID().uuidString.lowercased(),
            ownerStoreID: UUID().uuidString.lowercased(), ownerEmail: claim.ownerEmail, preparedAt: claim.preparedAt,
            expectedRevision: claim.expectedRevision, expectedValue: claim.expectedValue, reviewedConflict: false, state: "prepared", publishedAt: nil)
        let nextClaim = f.base.application
        try await f.coordinator().synchronize(f.base.source)
        XCTAssertEqual(Set(f.releases.map(\.operationID)).count, 1)
        XCTAssertEqual(f.base.application, nextClaim)
        XCTAssertEqual(f.base.applyCalls, 0)
        XCTAssertTrue(try f.base.journal().pending.isEmpty)
    }

    func testEveryHandoffWriteBoundaryPreservesFenceAndRecoversWithoutModelWrite() async throws {
        let baseline = try Fixture(); defer { baseline.base.cleanup() }
        let (c, r) = try await baseline.paused()
        let start = baseline.base.memory.writes
        try await c.release(r, context: baseline.base.source)
        let count = baseline.base.memory.writes - start
        XCTAssertGreaterThanOrEqual(count, 3)
        for boundary in 1...count {
            for after in [false, true] {
                let f = try Fixture(); defer { f.base.cleanup() }
                let (coordinator, review) = try await f.paused()
                let target = f.base.memory.writes + boundary
                if after { f.base.memory.failAfter = target } else { f.base.memory.failBefore = target }
                do { try await coordinator.release(review, context: f.base.source); XCTFail("Boundary \(boundary)") } catch {}
                let fence = f.base.memory.saved[f.fenceKey]
                if fence == nil { XCTAssertTrue(f.releases.isEmpty) }
                f.base.memory.failAfter = nil; f.base.memory.failBefore = nil
                if fence == nil { try await coordinator.release(review, context: f.base.source) }
                else { try await f.coordinator().synchronize(f.base.source) }
                XCTAssertEqual(f.base.applyCalls, 0)
                XCTAssertEqual(try f.base.savedValue(), .text("Original office note"))
                XCTAssertTrue(try f.base.journal().pending.isEmpty)
                XCTAssertEqual(Set(f.releases.map(\.operationID)).count, 1)
                if let fence { XCTAssertEqual(f.base.memory.saved[f.fenceKey], fence) }
            }
        }
    }

    func testAppliedUncertainLegacyAndChangedOfficeWorkCannotBeReleased() async throws {
        for legacy in [false, true] {
            let f = try Fixture(); defer { f.base.cleanup() }
            let (coordinator, review) = try await f.paused()
            var journal = try f.base.journal()
            if legacy { journal.pending[review.id]?.writeBoundaryVersion = nil }
            else { journal.pending[review.id]?.phase = "applying"; journal.pending[review.id]?.application = review.edit.application }
            f.base.memory.saved[StaffOwnerFieldEditCoordinator.key(f.base.source.scope)] = try StaffWorkspacePublicationContract.encode(journal)
            do { try await coordinator.release(review, context: f.base.source); XCTFail() } catch {}
            XCTAssertNil(f.base.memory.saved[f.fenceKey]); XCTAssertTrue(f.releases.isEmpty)
        }
        let f = try Fixture(); defer { f.base.cleanup() }
        let (coordinator, review) = try await f.paused()
        try f.base.officeChange("Later office draft saved")
        do { try await coordinator.release(review, context: f.base.source); XCTFail() } catch {}
        XCTAssertNil(f.base.memory.saved[f.fenceKey]); XCTAssertTrue(f.releases.isEmpty)
        XCTAssertEqual(try f.base.savedValue(), .text("Later office draft saved"))
    }

    func testServerConflictRetainsFenceAndDoesNotReenableOldDeviceWrite() async throws {
        let f = try Fixture(); defer { f.base.cleanup() }
        let (coordinator, review) = try await f.paused()
        f.beforeRelease = { f.base.serverRevision += 1; f.base.serverValue = .text("New office value") }
        do { try await coordinator.release(review, context: f.base.source); XCTFail() } catch {}
        let fence = try XCTUnwrap(f.base.memory.saved[f.fenceKey])
        try await f.coordinator().synchronize(f.base.source)
        XCTAssertEqual(f.base.applyCalls, 0)
        XCTAssertEqual(f.base.memory.saved[f.fenceKey], fence)
        XCTAssertFalse(try f.base.journal().pending.isEmpty)
    }

    func testCorruptFenceFailsClosedBeforePrepareModelSaveOrResolution() async throws {
        let f = try Fixture(); defer { f.base.cleanup() }
        let (coordinator, review) = try await f.paused()
        f.base.memory.saved[f.fenceKey] = Data("broken".utf8)
        try await f.coordinator().synchronize(f.base.source)
        do { try await coordinator.keepOffice(review, context: f.base.source); XCTFail() } catch {}
        do { try await coordinator.release(review, context: f.base.source); XCTFail() } catch {}
        XCTAssertEqual(f.base.prepareRequests.count, 1); XCTAssertEqual(f.base.applyCalls, 0)
        XCTAssertEqual(f.base.memory.saved[f.fenceKey], Data("broken".utf8))
    }

    func testAuthorityChangeAfterServerReleaseRetainsOriginalForAuthorizedRetry() async throws {
        let f = try Fixture(); defer { f.base.cleanup() }
        let (coordinator, review) = try await f.paused()
        f.afterRelease = { f.base.allowed = false }
        do { try await coordinator.release(review, context: f.base.source); XCTFail() } catch {}
        XCTAssertNotNil(f.base.memory.saved[f.fenceKey]); XCTAssertNil(f.base.memory.saved[f.fenceKey + "\nreceipt"])
        f.afterRelease = nil; f.base.allowed = true
        try await f.coordinator().synchronize(f.base.source)
        XCTAssertEqual(f.base.applyCalls, 0)
        XCTAssertEqual(Set(f.releases.map(\.operationID)).count, 1)
    }

    func testSaveBoundaryIsDurableBeforeActualSwiftDataSaveAndCannotBeRelabeledUnapplied() async throws {
        let f = try Fixture(); defer { f.base.cleanup() }
        f.base.saveModel = { context in
            let pending = try XCTUnwrap(f.base.journal().pending[f.base.original.commandID])
            XCTAssertEqual(pending.phase, "applying"); XCTAssertEqual(pending.writeBoundaryVersion, 1)
            try context.save(); throw StaffReplicaSourceSyncError.storage
        }
        let coordinator = f.coordinator()
        try await coordinator.synchronize(f.base.source)
        XCTAssertEqual(try f.base.savedValue(), f.base.original.value)
        XCTAssertFalse(try XCTUnwrap(coordinator.reviews.first).canRelease)
        XCTAssertEqual(try f.base.journal().pending[f.base.original.commandID]?.phase, "applying")
        f.base.saveModel = nil
        try await coordinator.synchronize(f.base.source)
        XCTAssertEqual(try f.base.journal().pending[f.base.original.commandID]?.phase, "saved")
    }

    func testMalformedReceiptCannotClearOriginalFenceOrPendingIntent() async throws {
        let f = try Fixture(); defer { f.base.cleanup() }
        let (coordinator, review) = try await f.paused()
        f.afterRelease = {
            let original = f.receipt!
            f.receipt = .init(schema: original.schema, request: original.request, ownerEmail: original.ownerEmail,
                releasedAt: "2000-01-01T00:00:00Z", outcome: original.outcome)
        }
        do { try await coordinator.release(review, context: f.base.source); XCTFail() } catch {}
        XCTAssertNotNil(f.base.memory.saved[f.fenceKey]); XCTAssertNil(f.base.memory.saved[f.fenceKey + "\nreceipt"])
        XCTAssertFalse(try f.base.journal().pending.isEmpty)
        XCTAssertEqual(f.base.applyCalls, 0)
    }

    func testRejectedHandoffCanKeepNewOfficeValueWithoutRemovingWriteFence() async throws {
        let f = try Fixture(); defer { f.base.cleanup() }
        let (coordinator, review) = try await f.paused()
        f.beforeRelease = { f.base.serverRevision = 2; f.base.serverValue = .text("New office choice") }
        do { try await coordinator.release(review, context: f.base.source); XCTFail() } catch {}
        f.beforeRelease = nil
        try f.base.officeChange("New office choice")
        let recovery = f.coordinator()
        try await recovery.synchronize(f.base.source)
        let fresh = try XCTUnwrap(recovery.reviews.first)
        XCTAssertTrue(fresh.canKeepOffice); XCTAssertFalse(fresh.canApplyReviewed); XCTAssertFalse(fresh.canRelease)
        let bytes = try XCTUnwrap(f.base.memory.saved[f.fenceKey])
        try await recovery.keepOffice(fresh, context: f.base.source)
        try await f.coordinator().synchronize(f.base.source)
        XCTAssertEqual(try f.base.savedValue(), .text("New office choice"))
        XCTAssertEqual(f.base.memory.saved[f.fenceKey], bytes)
        XCTAssertNotNil(f.base.resolution); XCTAssertEqual(f.base.applyCalls, 0)
        XCTAssertTrue(try f.base.journal().pending.isEmpty)
    }

    func testActualPythonHandoffContractAndNextDeviceClaimRetainOriginalAuthor() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffOwnerFieldHandoffWireInterop", withExtension: "json"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func bytes(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: XCTUnwrap(raw[key]), options: [.sortedKeys]) }
        let claimed = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEdit.self, from: bytes("claimed"))
        let released = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEdit.self, from: bytes("released"))
        let receipt = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldHandoffReceipt.self, from: bytes("receipt"))
        let request = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldHandoffRequest.self, from: bytes("request"))
        let prepare = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldEditPrepare.self, from: bytes("prepare"))
        let next = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEditApplication.self, from: bytes("nextClaim"))
        let binding = CompanyCloudKitBinding(companyID: try XCTUnwrap(UUID(uuidString: claimed.request.companyID)),
            containerID: GunnAireCloudKit.containerIdentifier, environment: claimed.request.environment,
            replicaID: try XCTUnwrap(UUID(uuidString: claimed.request.replicaID)), cloudAccountHash: String(repeating: "a", count: 64),
            approvedAt: "2026-09-09T00:00:00Z")
        let scope = StaffReplicaSourceScope(backendOrigin: "https://fixture.gunnaire.invalid", actorEmail: receipt.ownerEmail,
            binding: binding, storeUUID: request.ownerStoreID)
        let fence = StaffOwnerFieldHandoffFence(version: 1, scope: scope, edit: claimed,
            pending: .init(edit: claimed, request: prepare, phase: "prepared", application: claimed.application, writeBoundaryVersion: 1), request: request)
        try receipt.validate(fence); try released.validate(scope); try next.validate(commandID: claimed.id)
        let encoded = try StaffWorkspacePublicationContract.encode(fence)
        XCTAssertEqual(try StaffOwnerFieldEditWire.decode(StaffOwnerFieldHandoffFence.self, from: encoded), fence)
        XCTAssertEqual(released.receipt, claimed.receipt); XCTAssertEqual(released.current, claimed.current)
        XCTAssertNil(released.application); XCTAssertNotEqual(next.ownerStoreID, request.ownerStoreID)
        XCTAssertNotEqual(next.operationID, request.claimOperationID)
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        invalid["unknown"] = NSNull()
        XCTAssertThrowsError(try StaffOwnerFieldEditWire.decode(StaffOwnerFieldHandoffFence.self,
            from: JSONSerialization.data(withJSONObject: invalid)))
        let foreignScope = StaffReplicaSourceScope(backendOrigin: scope.backendOrigin, actorEmail: "other.owner@example.invalid",
            binding: binding, storeUUID: scope.storeUUID)
        XCTAssertThrowsError(try fence.validate(foreignScope))
    }
}
