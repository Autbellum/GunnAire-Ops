import Foundation
import SwiftData
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffOwnerInvoiceCoordinatorTests: XCTestCase {
    @MainActor final class Fixture {
        let models: StaffOwnerInvoiceTests.Fixture
        let original: StaffOwnerInvoiceReview
        let records: [StaffWorkspacePublishedRecord]
        let memory = StaffWorkspaceRecoveryBoundaryTests.Memory()
        var generation = UUID()
        var version = "2026.09.11.64"
        var saved: StaffOwnerInvoiceSavedApplication?
        var posts: [Data] = []
        var calls: [(String, String)] = []
        var applyCalls = 0, versionCalls = 0
        var losePrepare = false, loseConfirm = false, published = false
        var versionCallback: (() -> Void)?
        var afterResponse: ((String, String) -> Void)?
        var mutateResponse: ((String, String, Data) throws -> Data)?
        var saveModel: ((ModelContext) throws -> Void)?
        var page: StaffOwnerInvoicePage?
        var currentReview: StaffOwnerInvoiceReview?
        var prepareRejection: String?
        init() throws { models = try .init(); original = try models.review(); records = try models.records() }
        var context: StaffReplicaSourceContext {
            .init(scope: models.scope, stamp: .init(generation: generation,
                session: .init(backendOrigin: models.scope.backendOrigin, email: models.scope.actorEmail,
                    tokenFingerprint: String(repeating: "f", count: 64), expiresAt: models.now.addingTimeInterval(3600))))
        }
        var summary: StaffWorkspacePublicationSummary {
            .init(conflicts: [], waitingForCloudKit: 0, hasMore: false, lastConfirmedAt: models.now,
                preparedStage: .init(version: 1, scope: models.scope, records: records.compactMap(\.live), cursor: nil, deletionKeys: []),
                sourceSequence: 1, publishedRecords: records)
        }
        func check(_ context: StaffReplicaSourceContext) throws {
            try models.check()
            guard context.scope == self.context.scope, context.stamp == self.context.stamp else { throw StaffReplicaSourceSyncError.access }
        }
        func journal() throws -> StaffOwnerInvoiceJournal {
            guard let bytes = memory.saved[StaffOwnerInvoiceCoordinator.key(models.scope)] else { return .init(version: 1, scope: models.scope) }
            return try StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceJournal.self, from: bytes, maximum: 64 * 1024 * 1024)
        }
        func completed(_ receipt: StaffOwnerInvoiceApplication) -> StaffOwnerInvoiceApplication {
            .init(schema: receipt.schema, companyID: receipt.companyID, environment: receipt.environment, replicaID: receipt.replicaID,
                commandID: receipt.commandID, operationID: receipt.operationID, ownerStoreID: receipt.ownerStoreID, ownerEmail: receipt.ownerEmail,
                invoiceID: receipt.invoiceID, preparedAt: receipt.preparedAt, state: "published", publishedAt: "2026-09-11T08:00:02Z",
                qboPublished: false, proposalSHA256: receipt.proposalSHA256)
        }
        func response(_ path: String, method: String, body: Data?) throws -> Data {
            XCTAssertTrue(StaffOwnerInvoiceTransport.allows(path: path, method: method, body: body))
            calls.append((path, method)); defer { afterResponse?(path, method) }
            let result: Data
            if method == "POST", path.hasSuffix("/prepare") {
                let body = try XCTUnwrap(body), pending = try XCTUnwrap(journal().pending[original.id])
                XCTAssertEqual(pending.prepareBytes, body)
                let proposal = try StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceProposal.self, from: body)
                try proposal.validate(models.scope, original: original); posts.append(body)
                if let prepareRejection { throw StaffReplicaSourceRejected(code: prepareRejection) }
                if let saved { XCTAssertEqual(saved.proposal, proposal) }
                else { saved = .init(proposal: proposal, receipt: models.receipt(proposal)) }
                if losePrepare { losePrepare = false; throw StaffReplicaSourceSyncError.unavailable }
                result = try StaffWorkspacePublicationContract.encode(XCTUnwrap(saved).receipt)
            } else if method == "POST", path.hasSuffix("/confirm") {
                let value = try StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceConfirmation.self, from: XCTUnwrap(body))
                let prior = try XCTUnwrap(saved); XCTAssertEqual(value, prior.proposal.confirmation)
                guard published else { throw StaffReplicaSourceRejected(code: "invoice_not_published") }
                saved = .init(proposal: prior.proposal, receipt: completed(prior.receipt))
                if loseConfirm { loseConfirm = false; throw StaffReplicaSourceSyncError.unavailable }
                result = try StaffWorkspacePublicationContract.encode(XCTUnwrap(saved).receipt)
            } else if URLComponents(string: path)?.path == StaffOwnerInvoiceTransport.reviewRoot {
                result = try StaffWorkspacePublicationContract.encode(page ?? .init(schema: StaffInvoiceRequest.schema,
                    companyID: original.request.origin.companyID, environment: original.request.origin.environment,
                    replicaID: original.request.origin.replicaID, commandIDs: [original.id], nextCursor: nil))
            } else if path.contains("/invoice-applications/") {
                result = try StaffWorkspacePublicationContract.encode(StaffOwnerInvoiceApplicationEnvelope(schema: StaffOwnerInvoiceProposal.schema, application: saved))
            } else { result = try StaffWorkspacePublicationContract.encode(currentReview ?? original) }
            return try mutateResponse?(path, method, result) ?? result
        }
        func dependencies() -> StaffOwnerInvoiceDependencies {
            .init(check: check, request: { try self.response($0, method: $1, body: $2) }, store: memory.store,
                serviceVersion: { self.versionCalls += 1; self.versionCallback?(); return self.version },
                verify: { proposal, context, applied in
                    try self.check(context)
                    return try StaffOwnerInvoiceModels.verify(proposal, scope: context.scope, container: self.models.container, allowApplied: applied)
                }, apply: { proposal, receipt, context in
                    self.applyCalls += 1
                    XCTAssertEqual(try self.journal().pending[proposal.commandID]?.phase, "applying")
                    XCTAssertEqual(try self.journal().pending[proposal.commandID]?.receipt, receipt)
                    try StaffOwnerInvoiceModels.apply(proposal, application: receipt, scope: context.scope, container: self.models.container,
                        check: { try self.check(context) }, save: self.saveModel)
                }, now: { self.models.now })
        }
        func coordinator() -> StaffOwnerInvoiceCoordinator { .init(dependencies: dependencies()) }
        func draft(_ coordinator: StaffOwnerInvoiceCoordinator) async throws -> StaffOwnerInvoiceDraft {
            try await coordinator.refresh(context, published: summary)
            return try await coordinator.makeDraft(original.id, reason: "Office reviewed the original field work", context: context)
        }
        func itemCount() throws -> Int { try models.container.mainContext.fetchCount(FetchDescriptor<Item>()) }
    }
    func fails(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected failure", file: file, line: line) } catch { }
    }
    func testBackendGateRequiresProviderFencesAndStrictNumericVersion() {
        for version in ["2026.09.11.64", "2026.09.11.65", "2026.10.01.1"] { XCTAssertTrue(StaffOwnerInvoiceBackendGate.supports(version), version) }
        for version in ["2026.09.11.63", "2026.09.10.999", "2026.9.11", "2026.09.11.64-beta", "2026.09.11.+64", "2026.13.11.65", "2026.09.32.65", "2026.09.11.64.0", "2026.09.11.６４"] {
            XCTAssertFalse(StaffOwnerInvoiceBackendGate.supports(version), version)
        }
    }
    func testRefreshAndPreviewAreReadOnlyAndApplyNeedsExplicitReview() async throws {
        let f = try Fixture(), c = f.coordinator()
        try await c.recover(f.context)
        XCTAssertEqual(f.versionCalls, 0)
        let draft = try await f.draft(c)
        XCTAssertEqual(c.reviews.first?.customer, "Synthetic customer")
        XCTAssertTrue(f.posts.isEmpty); XCTAssertEqual(f.applyCalls, 0); XCTAssertEqual(f.models.invoice.amount, 0)
        XCTAssertTrue(try f.journal().pending.isEmpty)
        try await c.applyReviewed(draft, context: f.context)
        XCTAssertEqual(f.models.invoice.amount, 246.75); XCTAssertEqual(try f.itemCount(), 1)
        XCTAssertEqual(try f.journal().pending[f.original.id]?.phase, "saved")
        XCTAssertFalse(try XCTUnwrap(f.saved).receipt.qboPublished)
        try await c.confirmPublished(f.context) // Local save is not server confirmation.
        XCTAssertEqual(try f.journal().pending.count, 1)
        f.published = true
        try await c.confirmPublished(f.context)
        XCTAssertTrue(try f.journal().pending.isEmpty); XCTAssertEqual(f.saved?.receipt.state, "published")
        XCTAssertEqual(f.applyCalls, 1)
        XCTAssertTrue(f.calls.allSatisfy { $0.0.hasPrefix("/api/workspace/") })
    }
    func testLostPrepareReplaysIdenticalBytesAcrossRestartWithoutDuplicateItem() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.losePrepare = true
        await fails { try await c.applyReviewed(draft, context: f.context) }
        XCTAssertEqual(f.applyCalls, 0); XCTAssertEqual(try f.journal().pending[f.original.id]?.phase, "queued")
        try await f.coordinator().recover(f.context)
        XCTAssertEqual(f.posts.count, 2); XCTAssertEqual(f.posts.first, f.posts.last)
        XCTAssertEqual(f.models.invoice.amount, 246.75); XCTAssertEqual(try f.itemCount(), 1)
    }
    func testEveryDurableApplyWriteFailureBeforeAndAfterRetainsRecoverableOriginal() async throws {
        // Four writes: original intent, exclusive claim, entering model save, saved.
        for boundary in 1...4 {
            for after in [false, true] {
                let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
                let target = f.memory.writes + boundary
                if after { f.memory.failAfter = target } else { f.memory.failBefore = target }
                await fails { try await c.applyReviewed(draft, context: f.context) }
                if boundary == 1 && !after { XCTAssertTrue(f.posts.isEmpty); XCTAssertEqual(f.applyCalls, 0) }
                let retained = try f.journal().pending[f.original.id]
                f.memory.failBefore = nil; f.memory.failAfter = nil
                let restarted = f.coordinator()
                if retained == nil {
                    // No durable approval: explicitly review again, never auto-approve.
                    let again = try await f.draft(restarted)
                    try await restarted.applyReviewed(again, context: f.context)
                } else {
                    XCTAssertEqual(retained?.proposal, draft.proposal)
                    try await restarted.recover(f.context)
                }
                XCTAssertEqual(try f.journal().pending[f.original.id]?.phase, "saved", "boundary \(boundary), after \(after)")
                XCTAssertEqual(f.models.invoice.amount, 246.75); XCTAssertEqual(try f.itemCount(), 1)
                XCTAssertTrue(f.posts.dropFirst().allSatisfy { $0 == f.posts.first })
            }
        }
    }
    func testModelSaveFailureRecoversOriginalAndDoesNotLoseUnrelatedInvoice() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.saveModel = { _ in throw StaffOwnerInvoiceError.storage }
        await fails { try await c.applyReviewed(draft, context: f.context) }
        XCTAssertEqual(try f.journal().pending[f.original.id]?.phase, "applying")
        XCTAssertEqual(f.models.invoice.amount, 0); XCTAssertEqual(try f.itemCount(), 0)
        f.saveModel = nil; try await f.coordinator().recover(f.context)
        XCTAssertEqual(f.models.invoice.amount, 246.75); XCTAssertEqual(try f.itemCount(), 1)
    }
    func testLostModelSaveAcknowledgementUsesOriginalIdentity() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.saveModel = { context in try context.save(); throw StaffOwnerInvoiceError.storage }
        await fails { try await c.applyReviewed(draft, context: f.context) }
        XCTAssertEqual(f.models.invoice.amount, 246.75)
        f.saveModel = nil; try await f.coordinator().recover(f.context)
        XCTAssertEqual(try f.itemCount(), 1); XCTAssertEqual(f.models.invoice.amount, 246.75)
        XCTAssertEqual(f.posts.first, f.posts.last)
    }
    func testLostConfirmationNeverReappliesHistoricalInvoice() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        try await c.applyReviewed(draft, context: f.context)
        f.published = true; f.loseConfirm = true; try await c.confirmPublished(f.context)
        XCTAssertEqual(f.saved?.receipt.state, "published"); XCTAssertFalse(try f.journal().pending.isEmpty)
        f.models.invoice.quickBooksID = "provider-confirmed-later"; try f.models.container.mainContext.save()
        try await f.coordinator().recover(f.context)
        XCTAssertTrue(try f.journal().pending.isEmpty); XCTAssertEqual(f.applyCalls, 1)
        XCTAssertEqual(f.models.invoice.quickBooksID, "provider-confirmed-later")
    }
    func testConfirmJournalFailureBeforeAndAfterDoesNotReapply() async throws {
        for after in [false, true] {
            let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
            try await c.applyReviewed(draft, context: f.context); f.published = true
            if after { f.memory.failAfter = f.memory.writes + 1 } else { f.memory.failBefore = f.memory.writes + 1 }
            try await c.confirmPublished(f.context)
            f.memory.failBefore = nil; f.memory.failAfter = nil
            try await f.coordinator().recover(f.context)
            XCTAssertTrue(try f.journal().pending.isEmpty); XCTAssertEqual(f.applyCalls, 1)
        }
    }
    func testOldBackendDisablesPreviewAndRecoveryWithoutWrites() async throws {
        let f = try Fixture(), c = f.coordinator()
        f.version = "2026.09.11.63"; try await c.refresh(f.context, published: f.summary)
        XCTAssertTrue(c.reviews.isEmpty); XCTAssertTrue(c.message.contains("server update")); XCTAssertTrue(f.calls.isEmpty)
        f.version = "2026.09.11.64"; let draft = try await f.draft(c); f.losePrepare = true
        await fails { try await c.applyReviewed(draft, context: f.context) }
        f.version = "2026.09.11.63"; let count = f.calls.count
        await fails { try await f.coordinator().recover(f.context) }
        XCTAssertEqual(f.calls.count, count); XCTAssertEqual(f.applyCalls, 0); XCTAssertFalse(try f.journal().pending.isEmpty)
    }
    func testChangedSessionOrInvoiceCannotApplyDisplayedDraft() async throws {
        for session in [false, true] {
            let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
            if session { f.generation = UUID() }
            else { f.models.invoice.lineItemSummary = "A newer office description"; try f.models.container.mainContext.save() }
            await fails { try await c.applyReviewed(draft, context: f.context) }
            XCTAssertTrue(f.posts.isEmpty); XCTAssertEqual(f.applyCalls, 0)
        }
    }
    func testRevocationAfterEachNetworkBoundaryRetainsIntentWithoutApplying() async throws {
        for boundary in 1...5 {
            let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
            var replies = 0
            f.afterResponse = { _, _ in replies += 1; if replies == boundary { f.models.allowed = false } }
            await fails { try await c.applyReviewed(draft, context: f.context) }
            XCTAssertEqual(f.applyCalls, 0); XCTAssertEqual(f.models.invoice.amount, 0)
            f.models.allowed = true; f.afterResponse = nil
            if try !f.journal().pending.isEmpty { try await f.coordinator().recover(f.context); XCTAssertEqual(f.models.invoice.amount, 246.75) }
        }
    }
    func testRevocationAfterVersionAndJournalReadStopsBeforeNetworkMutation() async throws {
        for read in [false, true] {
            let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
            if read { f.memory.onRead = { _ in f.models.allowed = false } }
            else { f.versionCallback = { f.models.allowed = false } }
            await fails { try await c.applyReviewed(draft, context: f.context) }
            XCTAssertTrue(f.posts.isEmpty); XCTAssertEqual(f.applyCalls, 0)
        }
    }
    func testAlteredSavedProposalEvenWithSameHashNeverApplies() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.mutateResponse = { path, method, bytes in
            guard method == "GET", path.contains("/invoice-applications/"), f.saved != nil else { return bytes }
            return try StaffOwnerInvoiceTests().mutate(StaffWorkspacePublicationContract.decode(StaffOwnerInvoiceApplicationEnvelope.self, from: bytes)) { object in
                var application = object["application"] as! [String: Any]
                var proposal = application["proposal"] as! [String: Any]
                proposal["reason"] = "Changed reason with same hash"
                application["proposal"] = proposal; object["application"] = application
            }.encodedForInvoiceTest()
        }
        await fails { try await c.applyReviewed(draft, context: f.context) }
        XCTAssertEqual(f.applyCalls, 0); XCTAssertEqual(f.models.invoice.amount, 0)
        XCTAssertEqual(try f.journal().pending[f.original.id]?.proposal, draft.proposal)
    }
    func testOtherDeviceClaimCannotBeAdopted() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.losePrepare = true; await fails { try await c.applyReviewed(draft, context: f.context) }
        let original = try XCTUnwrap(f.saved)
        let other = UUID().uuidString.lowercased()
        let proposal = try StaffOwnerInvoiceTests().mutate(original.proposal) { $0["ownerStoreID"] = other }
        let receipt = try StaffOwnerInvoiceTests().mutate(original.receipt) { $0["ownerStoreID"] = other }
        f.saved = .init(proposal: proposal, receipt: receipt)
        try await f.coordinator().recover(f.context)
        XCTAssertEqual(f.applyCalls, 0); XCTAssertEqual(f.posts.count, 1); XCTAssertFalse(try f.journal().pending.isEmpty)
    }
    func testCorruptOriginalBytesFailClosedWithoutClaimOrSave() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.losePrepare = true; await fails { try await c.applyReviewed(draft, context: f.context) }
        var journal = try f.journal(); let pending = try XCTUnwrap(journal.pending[f.original.id])
        journal.pending[f.original.id] = .init(review: pending.review, proposal: pending.proposal,
            prepareBytes: Data("{}".utf8), phase: pending.phase, receipt: pending.receipt)
        f.memory.saved[StaffOwnerInvoiceCoordinator.key(f.models.scope)] = try StaffWorkspacePublicationContract.encode(journal)
        let count = f.calls.count; await fails { try await f.coordinator().recover(f.context) }
        XCTAssertEqual(f.calls.count, count); XCTAssertEqual(f.applyCalls, 0)
    }
    func testSourceSyncRecoversApprovedInvoiceBeforeAnyNewCapture() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.losePrepare = true; await fails { try await c.applyReviewed(draft, context: f.context) }
        var captured = false
        let source = StaffReplicaSourceCoordinator(dependencies: .init(context: { f.context }, check: f.check,
            capture: { _, _ in captured = true; XCTAssertEqual(f.models.invoice.amount, 246.75); throw StaffReplicaSourceSyncError.history },
            request: { _, _, _ in XCTFail("Unexpected core request"); throw StaffReplicaSourceSyncError.invalid },
            store: StaffWorkspaceRecoveryBoundaryTests.Memory().store, ownerInvoices: f.coordinator()))
        await source.sync()
        XCTAssertTrue(captured); XCTAssertEqual(try f.itemCount(), 1)
    }
    func testUnclaimedRejectionArchivesOriginalAndAllowsFreshHumanReview() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.prepareRejection = "invoice_changed"
        await fails { try await c.applyReviewed(draft, context: f.context) }
        XCTAssertTrue(try f.journal().pending.isEmpty)
        XCTAssertEqual(try f.journal().rejected.first?.pending.proposal, draft.proposal)
        XCTAssertEqual(try f.journal().rejected.first?.pending.prepareBytes, f.posts.first)
        XCTAssertEqual(f.applyCalls, 0)
        f.prepareRejection = nil
        let next = try await f.draft(c)
        XCTAssertNotEqual(next.id, draft.id)
        try await c.applyReviewed(next, context: f.context)
        XCTAssertEqual(f.models.invoice.amount, 246.75); XCTAssertEqual(try f.itemCount(), 1)
        XCTAssertEqual(try f.journal().rejected.count, 1)
    }
    func testRejectionWithExistingOrUncertainClaimKeepsOriginalPending() async throws {
        for existing in [false, true] {
            let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
            if existing {
                f.losePrepare = true; await fails { try await c.applyReviewed(draft, context: f.context) }
                f.prepareRejection = "invoice_changed"
                try await c.recover(f.context)
            } else {
                f.prepareRejection = "invoice_changed"
                f.mutateResponse = { path, method, bytes in
                    if method == "GET", path.contains("/invoice-applications/"), !f.posts.isEmpty { throw StaffReplicaSourceSyncError.unavailable }
                    return bytes
                }
                await fails { try await c.applyReviewed(draft, context: f.context) }
            }
            XCTAssertEqual(try f.journal().pending[f.original.id]?.proposal, draft.proposal)
            XCTAssertTrue(try f.journal().rejected.isEmpty); XCTAssertEqual(f.applyCalls, 0)
        }
    }
    func testFailedPendingApprovalDoesNotRequestOneSecondRetryLoop() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.losePrepare = true; await fails { try await c.applyReviewed(draft, context: f.context) }
        f.prepareRejection = "invoice_changed"
        try await c.recover(f.context)
        XCTAssertFalse(c.hasMore)
        try await c.refresh(f.context, published: f.summary)
        XCTAssertFalse(c.hasMore); XCTAssertFalse(try f.journal().pending.isEmpty)
        XCTAssertEqual(c.reviews.first?.canReview, false)
        XCTAssertTrue(c.reviews.first?.message.contains("retained") == true)
    }
    func testPublishedRequestsLeaveActionQueueWithoutClaimingQBOCompletion() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        try await c.applyReviewed(draft, context: f.context); f.published = true
        try await c.confirmPublished(f.context); try await c.refresh(f.context, published: f.summary)
        XCTAssertTrue(c.reviews.isEmpty); XCTAssertFalse(c.hasMore)
        XCTAssertEqual(f.saved?.receipt.qboPublished, false)
    }
    func testInvalidClaimChronologyAndUnexpectedQBOFlagNeverApply() async throws {
        for field in ["preparedAt", "qboPublished", "proposalSHA256"] {
            let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
            f.mutateResponse = { path, method, bytes in
                guard method == "POST", path.hasSuffix("/prepare") else { return bytes }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                if field == "preparedAt" { object[field] = "2026-09-11T07:58:00Z" }
                else if field == "qboPublished" { object[field] = true }
                else { object[field] = "not-a-digest" }
                return try JSONSerialization.data(withJSONObject: object)
            }
            await fails { try await c.applyReviewed(draft, context: f.context) }
            XCTAssertEqual(f.applyCalls, 0); XCTAssertFalse(try f.journal().pending.isEmpty)
        }
    }
    func testMalformedOrDuplicateResponseKeysAndPaginationCannotCreateReview() async throws {
        for duplicate in [false, true] {
            let f = try Fixture(), c = f.coordinator()
            f.mutateResponse = { path, _, bytes in
                guard URLComponents(string: path)?.path == StaffOwnerInvoiceTransport.reviewRoot else { return bytes }
                if duplicate { return Data("{\"schema\":\"extra\",".utf8) + bytes.dropFirst() }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                object["nextCursor"] = f.original.id // A short page cannot claim continuation.
                return try JSONSerialization.data(withJSONObject: object)
            }
            await fails { try await c.refresh(f.context, published: f.summary) }
            XCTAssertTrue(c.reviews.isEmpty); XCTAssertTrue(f.posts.isEmpty)
        }
    }
    func testPreviewUsesCompleteSoldSnapshotAndClearDisplayInvalidatesSheet() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        let preview = try StaffOwnerInvoicePreview(draft.proposal)
        XCTAssertEqual(preview.amount, 246.75); XCTAssertEqual(preview.lines.count, 1); XCTAssertTrue(preview.createsItem)
        XCTAssertEqual(preview.lines.first?.servicedEquipment?.serialNumber, "TEST-ONLY")
        let generation = c.displayGeneration; c.clearDisplay()
        XCTAssertNotEqual(c.displayGeneration, generation); XCTAssertTrue(c.reviews.isEmpty)
        await fails { try await c.applyReviewed(draft, context: f.context) }
        XCTAssertTrue(f.posts.isEmpty)
    }
}

private extension Encodable {
    func encodedForInvoiceTest() throws -> Data { try StaffWorkspacePublicationContract.encode(self) }
}
