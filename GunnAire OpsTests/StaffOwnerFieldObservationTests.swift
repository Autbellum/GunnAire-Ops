import Foundation
import SwiftData
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffOwnerFieldObservationTests: XCTestCase {
    @MainActor final class Fixture {
        let f: StaffOwnerFieldEditTests.Fixture
        let claim: StaffOwnerFieldEditApplication
        var requests: [StaffOwnerFieldObservationRequest] = []
        var receipts: [String: StaffOwnerFieldObservationReceipt] = [:]
        var reject = false, loseReply = false, revokeAfterReply = false
        var corruptReply = false
        init() throws {
            f = try .init()
            claim = .init(schema: StaffOwnerFieldEdit.schema, commandID: f.original.commandID,
                operationID: UUID().uuidString.lowercased(), ownerStoreID: UUID().uuidString.lowercased(),
                ownerEmail: f.source.scope.actorEmail, preparedAt: "2026-09-10T08:01:00Z", expectedRevision: 1,
                expectedValue: f.edit.baseValue, reviewedConflict: false, state: "prepared", publishedAt: nil)
            f.application = claim
            try f.officeChange("Technician found a failed capacitor")
            f.serverValue = f.original.value; f.serverRevision = 2
        }
        func publish() {
            f.application = .init(schema: claim.schema, commandID: claim.commandID, operationID: claim.operationID,
                ownerStoreID: claim.ownerStoreID, ownerEmail: claim.ownerEmail, preparedAt: claim.preparedAt,
                expectedRevision: claim.expectedRevision, expectedValue: claim.expectedValue,
                reviewedConflict: claim.reviewedConflict, state: "published", publishedAt: "2026-09-10T08:02:00Z")
        }
        func coordinator() -> StaffOwnerFieldEditCoordinator {
            .init(dependencies: .init(check: f.check, request: { path, method, data in
                guard path.hasSuffix("/confirm-observed") else { return try self.f.response(path, method: method, bytes: data) }
                XCTAssertTrue(StaffOwnerFieldEditTransport.allows(path: path, method: method, body: data))
                let request = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldObservationRequest.self, from: XCTUnwrap(data))
                self.requests.append(request)
                guard !self.reject else { throw StaffReplicaSourceSyncError.unavailable }
                if self.receipts[request.operationID] == nil {
                    guard request.expectedRevision == self.f.serverRevision, request.expectedValue == self.f.serverValue else { throw StaffReplicaSourceRejected(code: "field_changed") }
                    self.publish()
                    self.receipts[request.operationID] = .init(schema: StaffOwnerFieldObservationRequest.schema, request: request,
                        ownerEmail: self.claim.ownerEmail, observedAt: "2026-09-10T08:03:00Z", application: try XCTUnwrap(self.f.application))
                }
                XCTAssertEqual(self.receipts[request.operationID]?.request, request)
                if self.loseReply { self.loseReply = false; throw StaffReplicaSourceSyncError.unavailable }
                if self.revokeAfterReply { self.f.allowed = false }
                if self.corruptReply { return Data("{}".utf8) }
                return try StaffWorkspacePublicationContract.encode(XCTUnwrap(self.receipts[request.operationID]))
            }, store: f.memory.store, read: { edit, context in
                try self.f.check(context); return try StaffOwnerFieldEditModels.read(edit, container: self.f.container)
            }, apply: { _, _, _ in self.f.applyCalls += 1; XCTFail("Observation must never apply a field value") }))
        }
        func review(_ coordinator: StaffOwnerFieldEditCoordinator) async throws -> StaffOwnerFieldEditReview {
            try await coordinator.synchronize(f.source)
            return try XCTUnwrap(coordinator.reviews.first)
        }
        func archive(_ operation: String, superseded: Bool = false) throws -> StaffOwnerFieldObservationArchive {
            let key = StaffOwnerFieldEditCoordinator.observationArchiveKey(f.source.scope, operationID: operation) + (superseded ? "\nsuperseded" : "")
            let value = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldObservationArchive.self,
                from: XCTUnwrap(f.memory.saved[key]), maximum: 64 * 1024 * 1024)
            try value.validate(f.source.scope); return value
        }
    }

    func testConfirmedExistingValuePreservesOriginalClaimAndDoesNotWriteModels() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator()
        let review = try await h.review(c)
        XCTAssertTrue(review.canConfirmObserved); XCTAssertFalse(review.canApplyReviewed); XCTAssertFalse(review.canKeepOffice)
        try await c.confirmObserved(review, context: h.f.source)
        XCTAssertEqual(h.f.applyCalls, 0); XCTAssertTrue(h.f.prepareRequests.isEmpty)
        XCTAssertEqual(h.f.application?.operationID, h.claim.operationID)
        XCTAssertEqual(h.f.application?.ownerStoreID, h.claim.ownerStoreID)
        XCTAssertTrue(try h.f.journal().observations?.isEmpty == true)
        let archive = try h.archive(XCTUnwrap(h.requests.first).operationID)
        XCTAssertEqual(archive.pending.edit.receipt, h.f.receipt)
        XCTAssertNotNil(archive.receipt); XCTAssertNil(archive.publishedElsewhere)
        XCTAssertEqual(try h.f.savedValue(), h.f.original.value)
    }

    func testLostReplyRelaunchUsesOriginalOperationEvenAfterNewOfficeChange() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator()
        let review = try await h.review(c); h.loseReply = true
        do { try await c.confirmObserved(review, context: h.f.source); XCTFail() } catch {}
        let original = try XCTUnwrap(h.requests.first)
        XCTAssertEqual(try h.f.journal().observations?[review.id]?.request, original)
        try h.f.officeChange("Newer office correction"); h.f.serverValue = .text("Newer office correction"); h.f.serverRevision = 3
        try await h.coordinator().synchronize(h.f.source)
        XCTAssertEqual(h.requests, [original, original])
        XCTAssertEqual(try h.archive(original.operationID).receipt?.request, original)
        XCTAssertEqual(try h.f.savedValue(), .text("Newer office correction")); XCTAssertEqual(h.f.applyCalls, 0)
    }

    func testCurrentSavedValueAndFreshServerReviewFenceTheAction() async throws {
        for changeLocal in [true, false] {
            let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator()
            let review = try await h.review(c)
            if changeLocal { try h.f.officeChange("New office change") } else { h.f.serverRevision = 3 }
            do { try await c.confirmObserved(review, context: h.f.source); XCTFail() } catch {}
            XCTAssertTrue(h.requests.isEmpty); XCTAssertEqual(h.f.application, h.claim)
        }
    }

    func testUnsavedMainContextSuppressesConfirmation() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; h.f.job.notes = "Unsaved office draft"
        let review = try await h.review(h.coordinator())
        XCTAssertFalse(review.canConfirmObserved); XCTAssertTrue(h.requests.isEmpty)
    }

    func testMismatchOrOriginalStoreCannotOfferObservation() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }
        h.f.serverValue = h.f.edit.baseValue
        let mismatch = try await h.review(h.coordinator())
        XCTAssertFalse(mismatch.canConfirmObserved)
        h.f.serverValue = h.f.original.value
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(h.claim)) as? [String: Any])
        for key in ["ownerStoreID", "ownerEmail"] {
            var altered = object
            altered[key] = key == "ownerStoreID" ? h.f.source.scope.storeUUID.lowercased() : "different@example.invalid"
            h.f.application = try JSONDecoder().decode(StaffOwnerFieldEditApplication.self, from: JSONSerialization.data(withJSONObject: altered))
            XCTAssertThrowsError(try StaffOwnerFieldObservationRequest(edit: h.f.edit, scope: h.f.source.scope, operation: UUID()))
        }
    }

    func testEveryDurableBoundaryRecoversWithoutApplyingOrReidentifying() async throws {
        for after in [false, true] { for boundary in 1...3 {
            let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator(); let review = try await h.review(c)
            let failure = h.f.memory.writes + boundary
            if after { h.f.memory.failAfter = failure } else { h.f.memory.failBefore = failure }
            do { try await c.confirmObserved(review, context: h.f.source); XCTFail("Injected write failure") } catch {}
            let first = h.requests.first
            h.f.memory.failBefore = nil; h.f.memory.failAfter = nil
            let restarted = h.coordinator(); try await restarted.synchronize(h.f.source)
            if let fresh = restarted.reviews.first, fresh.canConfirmObserved { try await restarted.confirmObserved(fresh, context: h.f.source) }
            XCTAssertEqual(h.f.application?.state, "published")
            XCTAssertTrue(try h.f.journal().observations?.isEmpty == true)
            if let first { XCTAssertTrue(h.requests.allSatisfy { $0 == first }) }
            XCTAssertEqual(h.f.applyCalls, 0)
        } }
    }

    func testRevocationAfterReplyKeepsOriginalPendingUntilAuthorizedRecovery() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator(); let review = try await h.review(c)
        h.revokeAfterReply = true
        do { try await c.confirmObserved(review, context: h.f.source); XCTFail() } catch {}
        XCTAssertNotNil(try h.f.journal().observations?[review.id])
        h.f.allowed = true; h.revokeAfterReply = false
        try await h.coordinator().synchronize(h.f.source)
        XCTAssertEqual(h.requests.count, 2); XCTAssertEqual(h.requests.first, h.requests.last)
        XCTAssertEqual(h.f.applyCalls, 0)
    }

    func testStaleObservationNeedsFreshReviewAndPreservesSupersededIntent() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator(); let review = try await h.review(c)
        h.reject = true
        do { try await c.confirmObserved(review, context: h.f.source); XCTFail() } catch {}
        let original = try XCTUnwrap(h.requests.first)
        h.reject = false; h.f.serverRevision = 3
        let restarted = h.coordinator(); let fresh = try await h.review(restarted)
        XCTAssertTrue(fresh.canConfirmObserved)
        try await restarted.confirmObserved(fresh, context: h.f.source)
        XCTAssertNotEqual(h.requests.last?.operationID, original.operationID)
        XCTAssertEqual(try h.archive(original.operationID, superseded: true).supersededAtRevision, 3)
        XCTAssertEqual(h.f.applyCalls, 0)
    }

    func testPublishedElsewhereRecoversWithoutFabricatingWitnessForRejectedRequest() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator(); let review = try await h.review(c)
        h.reject = true
        do { try await c.confirmObserved(review, context: h.f.source); XCTFail() } catch {}
        h.publish(); h.f.serverRevision = 3; h.f.serverValue = .text("Later data")
        try h.f.officeChange("Later data")
        try await h.coordinator().synchronize(h.f.source)
        let archive = try h.archive(XCTUnwrap(h.requests.first).operationID)
        XCTAssertNil(archive.receipt); XCTAssertEqual(archive.publishedElsewhere, h.f.application)
        XCTAssertEqual(try h.f.savedValue(), .text("Later data")); XCTAssertEqual(h.f.applyCalls, 0)
    }

    func testCorruptArchiveRetainsPendingAndIsNotOverwritten() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator(); let review = try await h.review(c)
        h.loseReply = true
        do { try await c.confirmObserved(review, context: h.f.source); XCTFail() } catch {}
        let key = StaffOwnerFieldEditCoordinator.observationArchiveKey(h.f.source.scope, operationID: try XCTUnwrap(h.requests.first).operationID)
        h.f.memory.saved[key] = Data("corrupt".utf8)
        try await h.coordinator().synchronize(h.f.source)
        XCTAssertEqual(h.f.memory.saved[key], Data("corrupt".utf8))
        XCTAssertNotNil(try h.f.journal().observations?[review.id]); XCTAssertEqual(h.f.applyCalls, 0)
    }

    func testMalformedReplyNeverClearsUnconfirmedOriginal() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator(); let review = try await h.review(c)
        h.corruptReply = true
        do { try await c.confirmObserved(review, context: h.f.source); XCTFail() } catch {}
        XCTAssertNotNil(try h.f.journal().observations?[review.id]); XCTAssertEqual(h.f.applyCalls, 0)
    }

    func testObservationWireRejectsUnknownNullAndAcceptsOnlyDocumentedJournalNulls() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator(); let review = try await h.review(c)
        try await c.confirmObserved(review, context: h.f.source)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: StaffWorkspacePublicationContract.encode(XCTUnwrap(h.receipts.values.first))) as? [String: Any])
        raw["unknown"] = NSNull()
        XCTAssertThrowsError(try StaffOwnerFieldEditWire.decode(StaffOwnerFieldObservationReceipt.self, from: JSONSerialization.data(withJSONObject: raw)))
        var journal = try h.f.journal()
        journal.observations = [review.id: .init(edit: review.edit, request: try .init(edit: review.edit, scope: h.f.source.scope, operation: UUID()))]
        var bytes = try StaffWorkspacePublicationContract.encode(journal)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["keepOffice"] = NSNull(); object["after"] = NSNull()
        bytes = try JSONSerialization.data(withJSONObject: object)
        let decoded = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEditJournal.self, from: bytes)
        XCTAssertEqual(decoded.observations?[review.id], journal.observations?[review.id])
    }

    func testActualPythonHTTPWitnessRetainsOriginalClaimAndAuthor() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "StaffOwnerFieldObservationWireInterop", withExtension: "json"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        func bytes(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: XCTUnwrap(raw[key]), options: [.sortedKeys]) }
        let original = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEdit.self, from: bytes("claimed"))
        let completed = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldEdit.self, from: bytes("completed"))
        let receipt = try StaffOwnerFieldEditWire.decode(StaffOwnerFieldObservationReceipt.self, from: bytes("observation"))
        let request = try StaffWorkspacePublicationContract.decode(StaffOwnerFieldObservationRequest.self, from: bytes("request"))
        let binding = CompanyCloudKitBinding(companyID: try XCTUnwrap(UUID(uuidString: original.request.companyID)),
            containerID: GunnAireCloudKit.containerIdentifier, environment: original.request.environment,
            replicaID: try XCTUnwrap(UUID(uuidString: original.request.replicaID)), cloudAccountHash: String(repeating: "a", count: 64),
            approvedAt: "2026-09-09T00:00:00Z")
        let scope = StaffReplicaSourceScope(backendOrigin: "https://fixture.gunnaire.invalid", actorEmail: receipt.ownerEmail,
            binding: binding, storeUUID: request.observerStoreID)
        try original.validate(scope); try completed.validate(scope)
        try receipt.validate(.init(edit: original, request: request), scope: scope)
        XCTAssertEqual(completed.application, receipt.application)
        XCTAssertEqual(completed.receipt, original.receipt); XCTAssertEqual(completed.current, original.current)
        XCTAssertNotEqual(receipt.application.ownerStoreID, request.observerStoreID)
    }

    func testSavedValueIsRecheckedAfterDetailReplyBeforeDurableIntent() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator(); let review = try await h.review(c)
        h.f.afterResponse = { h.f.job.notes = "New unsaved draft" }
        do { try await c.confirmObserved(review, context: h.f.source); XCTFail() } catch {}
        XCTAssertTrue(h.requests.isEmpty); XCTAssertNil(try h.f.journal().observations?[review.id])
        XCTAssertEqual(h.f.job.notes, "New unsaved draft")
    }

    func testSupersessionWriteInterruptedThenOriginalDevicePublishesDoesNotStrandIntent() async throws {
        let h = try Fixture(); defer { h.f.cleanup() }; let c = h.coordinator(); let review = try await h.review(c)
        h.reject = true
        do { try await c.confirmObserved(review, context: h.f.source); XCTFail() } catch {}
        let original = try XCTUnwrap(h.requests.first)
        h.f.serverRevision = 3
        let restarted = h.coordinator(); let fresh = try await h.review(restarted)
        h.f.memory.failAfter = h.f.memory.writes + 1
        do { try await restarted.confirmObserved(fresh, context: h.f.source); XCTFail() } catch {}
        h.f.memory.failAfter = nil; h.publish()
        try await h.coordinator().synchronize(h.f.source)
        XCTAssertEqual(try h.archive(original.operationID, superseded: true).supersededAtRevision, 3)
        XCTAssertNotNil(try h.archive(original.operationID).publishedElsewhere)
        XCTAssertTrue(try h.f.journal().observations?.isEmpty == true); XCTAssertEqual(h.f.applyCalls, 0)
    }
}
