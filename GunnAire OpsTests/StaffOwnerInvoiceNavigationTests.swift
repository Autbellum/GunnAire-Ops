import Foundation
import SwiftData
import XCTest
@testable import GunnAire_Ops

@MainActor final class StaffOwnerInvoiceNavigationTests: XCTestCase {
    typealias Fixture = StaffOwnerInvoiceCoordinatorTests.Fixture

    func route(_ f: Fixture) throws -> StaffOwnerInvoiceRoute {
        try .init(review: f.original, context: f.context, customer: "Synthetic customer")
    }
    func resolve(_ route: StaffOwnerInvoiceRoute, _ f: Fixture) throws -> Invoice {
        try route.resolve(invoices: [f.models.invoice], customers: [f.models.customer], jobs: [f.models.job], check: f.check)
    }

    func testSourceConfirmedRequestOpensOriginalWithoutWritingOrClaimingQBOCompletion() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        XCTAssertTrue(c.recentInvoices.isEmpty)
        try await c.applyReviewed(draft, context: f.context)
        XCTAssertTrue(c.recentInvoices.isEmpty, "A local save must not invite editing before source confirmation")
        try await c.refresh(f.context, published: f.summary)
        XCTAssertTrue(c.recentInvoices.isEmpty)
        f.published = true
        try await c.confirmPublished(f.context)
        try await c.refresh(f.context, published: f.summary)
        let route = try XCTUnwrap(c.recentInvoices.first)
        XCTAssertTrue(c.canOpenInvoice(route))
        let before = try f.models.records(), calls = f.calls.count, writes = f.memory.writes
        XCTAssertTrue(try resolve(route, f) === f.models.invoice)
        XCTAssertEqual(route.invoiceID.uuidString.lowercased(), draft.proposal.expectedInvoice.id)
        XCTAssertEqual(try f.models.records(), before)
        XCTAssertEqual(f.calls.count, calls); XCTAssertEqual(f.memory.writes, writes)
        XCTAssertFalse(f.models.container.mainContext.hasChanges)
        XCTAssertFalse(try XCTUnwrap(f.saved).receipt.qboPublished)
        XCTAssertNil(f.models.invoice.quickBooksID)
    }

    func testPublishedHistoryRestoresHandoffWithoutReapplyingAndDeduplicates() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        try await c.applyReviewed(draft, context: f.context); f.published = true
        try await c.confirmPublished(f.context)
        let restarted = f.coordinator()
        for _ in 0..<3 { try await restarted.refresh(f.context, published: f.summary) }
        XCTAssertTrue(restarted.reviews.isEmpty)
        XCTAssertEqual(restarted.recentInvoices.count, 1)
        XCTAssertTrue(try resolve(XCTUnwrap(restarted.recentInvoices.first), f) === f.models.invoice)
        XCTAssertEqual(f.applyCalls, 1); XCTAssertEqual(try f.itemCount(), 1)
        restarted.clearDisplay(); XCTAssertTrue(restarted.recentInvoices.isEmpty)
    }

    func testCachedFollowupWaitsForDurableOriginalRecovery() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        try await c.applyReviewed(draft, context: f.context)
        let retained = try f.journal().pending
        f.published = true
        try await c.confirmPublished(f.context); try await c.refresh(f.context, published: f.summary)
        XCTAssertEqual(c.recentInvoices.count, 1)
        let opened = try XCTUnwrap(c.recentInvoices.first)
        XCTAssertTrue(c.canOpenInvoice(opened))
        // A restored journal may still retain the original approval even when
        // the server already confirmed it. Cached navigation is not authority.
        var journal = try f.journal(); journal.pending = retained
        f.memory.saved[StaffOwnerInvoiceCoordinator.key(f.models.scope)] = try StaffWorkspacePublicationContract.encode(journal)
        try await c.refresh(f.context, published: f.summary)
        XCTAssertTrue(c.recentInvoices.isEmpty)
        XCTAssertFalse(c.canOpenInvoice(opened), "An already-open sheet must also lose editing access")
        try await c.recover(f.context); try await c.refresh(f.context, published: f.summary)
        XCTAssertEqual(c.recentInvoices.count, 1); XCTAssertEqual(f.applyCalls, 1)
        XCTAssertTrue(c.canOpenInvoice(opened))
    }

    func confirmed(_ f: Fixture, _ c: StaffOwnerInvoiceCoordinator) async throws -> StaffOwnerInvoiceRoute {
        let draft = try await f.draft(c)
        try await c.applyReviewed(draft, context: f.context); f.published = true
        try await c.confirmPublished(f.context); try await c.refresh(f.context, published: f.summary)
        return try XCTUnwrap(c.recentInvoices.first)
    }

    func testCapturedHandoffInvalidatesDuringRecoveryBeforeRefresh() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        try await c.applyReviewed(draft, context: f.context)
        let retained = try f.journal().pending
        f.published = true
        try await c.confirmPublished(f.context); try await c.refresh(f.context, published: f.summary)
        let opened = try XCTUnwrap(c.recentInvoices.first)
        var journal = try f.journal(); journal.pending = retained
        f.memory.saved[StaffOwnerInvoiceCoordinator.key(f.models.scope)] = try StaffWorkspacePublicationContract.encode(journal)
        var checked = false
        f.versionCallback = {
            checked = true
            XCTAssertFalse(c.canOpenInvoice(opened), "Pending intent must close the handoff before the first await finishes")
        }
        try await c.recover(f.context)
        XCTAssertTrue(checked); XCTAssertFalse(c.canOpenInvoice(opened))
        try await c.refresh(f.context, published: f.summary)
        XCTAssertTrue(c.canOpenInvoice(opened)); XCTAssertEqual(f.applyCalls, 1)
    }

    func testUnreadableJournalInvalidatesOpenHandoffUntilRevalidated() async throws {
        let f = try Fixture(), c = f.coordinator(), opened = try await confirmed(f, c)
        let key = StaffOwnerInvoiceCoordinator.key(f.models.scope), original = f.memory.saved[key]
        f.memory.saved[key] = Data("not a valid journal".utf8)
        do { try await c.recover(f.context); XCTFail("Expected unreadable journal") } catch { }
        XCTAssertFalse(c.canOpenInvoice(opened)); XCTAssertTrue(c.recentInvoices.isEmpty)
        f.memory.saved[key] = original
        try await c.refresh(f.context, published: f.summary)
        XCTAssertTrue(c.canOpenInvoice(opened)); XCTAssertEqual(f.applyCalls, 1)
    }

    func testJournalWriteFailuresNeverLeaveOptimisticOpenHandoff() async throws {
        for boundary in 1...2 {
            for after in [false, true] {
                let f = try Fixture(), c = f.coordinator(), opened = try await confirmed(f, c)
                let target = f.memory.writes + boundary
                if after { f.memory.failAfter = target } else { f.memory.failBefore = target }
                do { try await c.refresh(f.context, published: f.summary); XCTFail("Expected write failure") } catch { }
                XCTAssertFalse(c.canOpenInvoice(opened), "boundary \(boundary), after \(after)")
                XCTAssertTrue(c.recentInvoices.isEmpty)
                f.memory.failBefore = nil; f.memory.failAfter = nil
                try await c.refresh(f.context, published: f.summary)
                XCTAssertTrue(c.canOpenInvoice(opened)); XCTAssertEqual(f.applyCalls, 1)
            }
        }
    }

    func testHandoffAvailabilityDoesNotReadJournalOrMutateModels() async throws {
        let f = try Fixture(), c = f.coordinator(), opened = try await confirmed(f, c)
        let before = try f.models.records(), calls = f.calls.count, writes = f.memory.writes
        f.memory.onRead = { _ in XCTFail("Rendering must not read the approval journal") }
        for _ in 0..<25 { XCTAssertTrue(c.canOpenInvoice(opened)) }
        XCTAssertEqual(f.calls.count, calls); XCTAssertEqual(f.memory.writes, writes)
        XCTAssertEqual(try f.models.records(), before)
        f.models.allowed = false
        XCTAssertFalse(c.canOpenInvoice(opened))
        f.models.allowed = true
        c.clearDisplay(); XCTAssertFalse(c.canOpenInvoice(opened))
    }

    func testHandoffRejectsUnconfirmedForeignStaleAndExpiredRoutes() async throws {
        let f = try Fixture()
        var now = f.models.now
        var dependencies = f.dependencies(); dependencies.now = { now }
        let c = StaffOwnerInvoiceCoordinator(dependencies: dependencies)
        XCTAssertFalse(c.canOpenInvoice(try route(f)))
        let opened = try await confirmed(f, c)
        XCTAssertTrue(c.canOpenInvoice(opened))
        let other = try Fixture()
        XCTAssertFalse(c.canOpenInvoice(try route(other)))
        now = opened.context.stamp.session.expiresAt
        XCTAssertFalse(c.canOpenInvoice(opened))
        now = f.models.now
        f.generation = UUID()
        XCTAssertFalse(c.canOpenInvoice(opened))
        XCTAssertFalse(c.canOpenInvoice(try route(f)), "New session cannot borrow a previous session's confirmation")
    }

    func testUnconfirmedFailedSaveDoesNotOfferSuccessfulHandoff() async throws {
        let f = try Fixture(), c = f.coordinator(), draft = try await f.draft(c)
        f.saveModel = { _ in throw StaffOwnerInvoiceError.storage }
        do { try await c.applyReviewed(draft, context: f.context); XCTFail("Expected save failure") } catch { }
        XCTAssertTrue(c.recentInvoices.isEmpty)
        XCTAssertFalse(try f.journal().pending.isEmpty)
    }

    func testMissingOrDuplicateInvoiceNeverFallsBackOrCoalesces() throws {
        let f = try Fixture(), r = try route(f)
        let unrelated = Invoice(customer: f.models.customer)
        XCTAssertNil(BillingFocusedInvoicePolicy.resolve(r.invoiceID, in: [unrelated]))
        let duplicate = Invoice(id: r.invoiceID, serviceCallID: f.models.job.id, customer: f.models.customer)
        XCTAssertNil(BillingFocusedInvoicePolicy.resolve(r.invoiceID, in: [f.models.invoice, duplicate]))
        XCTAssertNil(BillingFocusedInvoicePolicy.resolve(r.invoiceID, in: [f.models.invoice, f.models.invoice]))
        for invoices in [[], [unrelated], [f.models.invoice, duplicate]] {
            XCTAssertThrowsError(try r.resolve(invoices: invoices, customers: [f.models.customer], jobs: [f.models.job], check: f.check))
        }
        XCTAssertTrue(BillingFocusedInvoicePolicy.resolve(r.invoiceID, in: [unrelated, f.models.invoice]) === f.models.invoice)
    }

    func testWrongOrDuplicateCustomerAndJobFailClosed() throws {
        let f = try Fixture(), r = try route(f)
        let other = Customer(name: "Another synthetic customer")
        let duplicateCustomer = Customer(id: f.models.customer.id, name: "Duplicate synthetic customer")
        for customers in [[], [other], [duplicateCustomer], [f.models.customer, duplicateCustomer]] {
            XCTAssertThrowsError(try r.resolve(invoices: [f.models.invoice], customers: customers, jobs: [f.models.job], check: f.check))
        }
        XCTAssertThrowsError(try r.resolve(invoices: [f.models.invoice], customers: [f.models.customer], jobs: [], check: f.check))
        XCTAssertThrowsError(try r.resolve(invoices: [f.models.invoice], customers: [f.models.customer], jobs: [f.models.job, f.models.job], check: f.check))
        f.models.job.customer = other
        XCTAssertThrowsError(try resolve(r, f))
    }

    func testChangedInvoiceCustomerOrJobCannotReuseRoute() throws {
        let f = try Fixture(), r = try route(f)
        f.models.invoice.serviceCallID = UUID()
        XCTAssertThrowsError(try resolve(r, f))
        f.models.invoice.serviceCallID = f.models.job.id
        f.models.invoice.customer = Customer(name: "Changed synthetic customer")
        XCTAssertThrowsError(try resolve(r, f))
    }

    func testChangedSessionOrRevokedAuthorityInvalidatesCapturedRoute() throws {
        let f = try Fixture(), r = try route(f)
        f.generation = UUID()
        XCTAssertThrowsError(try resolve(r, f))
        let current = try route(f)
        f.models.allowed = false
        XCTAssertThrowsError(try resolve(current, f))
    }

    func testAuthorityIsRecheckedBeforeReturningModel() throws {
        let f = try Fixture(), r = try route(f)
        var checks = 0
        XCTAssertThrowsError(try r.resolve(invoices: [f.models.invoice], customers: [f.models.customer], jobs: [f.models.job]) { context in
            checks += 1
            if checks == 2 { f.models.allowed = false }
            try f.check(context)
        })
        XCTAssertEqual(checks, 2)
    }

    func testRouteCannotBeConstructedForAnotherCompany() throws {
        let f = try Fixture(), other = try Fixture()
        XCTAssertThrowsError(try StaffOwnerInvoiceRoute(review: f.original, context: other.context, customer: "Synthetic"))
    }

    func testStandaloneInvoiceDoesNotRequireOrInventAJob() throws {
        let f = try Fixture()
        f.models.invoice.serviceCallID = nil
        try f.models.container.mainContext.save()
        let original = try f.models.review()
        let origin = original.request.origin
        let standalone = StaffInvoiceOrigin(companyID: origin.companyID, environment: origin.environment,
            replicaID: origin.replicaID, selectionID: origin.selectionID, sourceSequence: origin.sourceSequence,
            contentSHA256: origin.contentSHA256, invoiceID: origin.invoiceID, invoiceRevision: origin.invoiceRevision,
            customerID: origin.customerID, jobID: nil)
        let request = StaffInvoiceRequest(origin: standalone, commandID: original.id,
            line: original.request.line, reason: original.request.reason)
        let prior = original.receipt
        let receipt = StaffInvoiceReceipt(schema: prior.schema, request: request, actorEmail: prior.actorEmail,
            shareID: prior.shareID, createdAt: prior.createdAt, state: prior.state,
            officeReviewRequired: prior.officeReviewRequired, qboPublished: prior.qboPublished, lineSubtotal: prior.lineSubtotal)
        let review = StaffOwnerInvoiceReview(schema: original.schema, request: request, receipt: receipt,
            baseInvoice: original.baseInvoice, baseInvoiceSHA256: original.baseInvoiceSHA256,
            baseItem: original.baseItem, baseItemSHA256: original.baseItemSHA256,
            currentInvoice: original.currentInvoice, currentItem: original.currentItem,
            invoiceUnchanged: original.invoiceUnchanged, itemUnchanged: original.itemUnchanged,
            currentSourceSequence: original.currentSourceSequence, sourceUnchanged: original.sourceUnchanged)
        let r = try StaffOwnerInvoiceRoute(review: review, context: f.context, customer: "Synthetic")
        XCTAssertNil(r.jobID)
        XCTAssertTrue(try r.resolve(invoices: [f.models.invoice], customers: [f.models.customer], jobs: [], check: f.check) === f.models.invoice)
        f.models.invoice.serviceCallID = f.models.job.id
        XCTAssertThrowsError(try resolve(r, f))
    }
}
