import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct SharedBillingConnectionTests {
    @Test func transportRetainsEveryBillingRouteButCannotBecomeAGeneralProxy() {
        let root = "/api/billing-publications", id = UUID().uuidString.lowercased()
        for path in [root + "?companyID=fixture", root + "/context?companyID=fixture", root + "/connection?companyID=fixture",
                     root + "/" + id, "/api/job-billing-assignments?companyID=fixture",
                     "/api/job-billing-assignments/connection?companyID=fixture"] {
            #expect(BillingPublicationTransportPolicy.allows(path: path, method: "GET", bodyBytes: nil))
            #expect(!BillingPublicationTransportPolicy.allows(path: path, method: "GET", bodyBytes: 2))
        }
        for path in [root, root + "/approve", root + "/\(id)/recover", root + "/\(id)/cancel", root + "/\(id)/approve",
                     root + "/draft-grants/\(id)/revoke", "/api/job-billing-assignments"] {
            #expect(BillingPublicationTransportPolicy.allows(path: path, method: "POST", bodyBytes: 2))
            #expect(!BillingPublicationTransportPolicy.allows(path: path + "?unexpected=1", method: "POST", bodyBytes: 2))
        }
        for path in ["https://foreign.invalid" + root, "//foreign.invalid" + root, root + "/../users", root + "/connection#fragment",
                     root + "/not-a-uuid", root + "/\(id)/delete", "/api/users", "/api/payments",
                     "/api/job-billing-assignments/connection/extra"] {
            #expect(!BillingPublicationTransportPolicy.allows(path: path, method: "GET", bodyBytes: nil))
            #expect(!BillingPublicationTransportPolicy.allows(path: path, method: "POST", bodyBytes: 2))
        }
        #expect(!BillingPublicationTransportPolicy.allows(path: root, method: "POST", bodyBytes: 1024 * 1024 + 1))
    }
    func connectionData(_ f: BillingNativeWorkflowTests.Fixture, path: String,
                        changes: [String: Any] = [:]) throws -> Data {
        let pairs = URLComponents(string: path)!.queryItems!
        var object: [String: Any] = Dictionary(uniqueKeysWithValues: pairs.map { ($0.name, $0.value!) })
        object.merge(["realmID": "billing-realm", "environment": Config.QuickBooks.environment,
                      "protocolVersion": 1, "connectionRevision": f.epoch]) { _, new in new }
        object.merge(changes) { _, new in new }
        return try f.encoded(object)
    }

    func prepare(_ f: BillingNativeWorkflowTests.Fixture, estimate: Bool = false,
                 current: @escaping () -> Bool = { true }, changes: [String: Any] = [:],
                 beforeDiscovery: @escaping () throws -> Void = {},
                 discoverError: Error? = nil) throws -> SharedBillingPreparation {
        let client = BillingPublicationClient { path, method, body in
            if path.hasPrefix("/api/billing-publications/connection?") {
                #expect(method == "GET" && body == nil)
                try beforeDiscovery()
                if let discoverError { throw discoverError }
                return try connectionData(f, path: path, changes: changes)
            }
            return try f.reply(path, method, body)
        }
        return try .init(document: estimate ? .estimate(f.app.estimate) : .invoice(f.app.invoice), context: f.app.context,
            isCurrent: current, validateAccess: { if !f.app.authorized { throw QuickBooksBillingWorkflowError.accessDenied } },
            client: client, catalog: { _ in throw CatalogPublicationError.accessRequired },
            customer: { _ in throw CustomerPublicationError.accessRequired }, fixtureCompanyID: f.company)
    }

    @Test func businessSessionInvoiceAndEstimatePublishWithoutAnyDeviceOAuth() async throws {
        for estimate in [false, true] {
            let f = try BillingNativeWorkflowTests.Fixture()
            let original = estimate ? f.app.estimate.catalogSnapshotJSON : f.app.invoice.catalogSnapshotJSON
            let flow = try await prepare(f, estimate: estimate).makeWorkflow(lifecycle: f.app.owner, billingJournal: f.app.billingJournal)
            #expect(flow.run.workflow.sharedBillingConnectionRevision == f.epoch)
            let result = try await flow.execute()
            #expect(result.invoice?.Id == "D1" || result.estimate?.Id == "D1")
            #expect(f.request?.document.Line.first?.SalesItemLineDetail.UnitPrice == 190)
            #expect(f.writes == 1 && f.app.requests.isEmpty)
            #expect((estimate ? f.app.estimate.catalogSnapshotJSON : f.app.invoice.catalogSnapshotJSON) == original)
            f.finish(flow)
        }
    }

    @Test func sharedAPIHasNoTokensAndDoesNotPretendToBeAnOAuthConnection() throws {
        let f = try BillingNativeWorkflowTests.Fixture()
        let identity = SharedBillingIdentity(companyID: f.company, documentType: .invoice,
            localDocumentID: f.app.invoice.id, localCustomerID: f.app.customer.id, serviceCallID: nil, projectMilestoneID: nil)
        let connection = try JSONDecoder().decode(SharedBillingConnection.self, from: connectionData(f, path: identity.path))
        try connection.validate(identity)
        let api = QuickBooksDataAPI(sharedBilling: connection, operation: .init(isCurrent: { true }),
            billingPublisher: f.app.billingPublisher!, catalogPublisher: { _ in throw CatalogPublicationError.unavailable },
            customerPublisher: { _ in throw CustomerPublicationError.unavailable })
        #expect(api.tokens == nil && !api.isAuthenticated)
        #expect(api.tokenExpiration == nil && !api.canUseQuickBooksPaymentsAPI)
        let workflow = try api.captureWorkspaceWorkflow()
        #expect(workflow.companyID == f.company && workflow.realmID == "billing-realm")
        let customer = try CustomerPublicationBoundary.request(workflow: workflow,
            draft: QuickBooksCustomerCreateOperation.draft(for: f.app.customer))
        #expect(customer.connectionRevision == f.epoch)
    }

    @Test func staleOrMalformedDiscoveryCannotStartAWorkflow() async throws {
        for changes: [String: Any] in [["companyID": UUID().uuidString], ["localDocumentID": UUID().uuidString],
            ["localCustomerID": UUID().uuidString], ["documentType": "Estimate"], ["realmID": ""],
            ["environment": "other"], ["connectionRevision": "A".padding(toLength: 64, withPad: "A", startingAt: 0)],
            ["protocolVersion": 2], ["serviceCallID": UUID().uuidString]] {
            let f = try BillingNativeWorkflowTests.Fixture(), preparation = try prepare(f, changes: changes)
            await #expect(throws: SharedBillingConnectionError.invalid) {
                try await preparation.makeWorkflow(lifecycle: f.app.owner)
            }
            #expect(f.app.owner.activeID == nil && f.writes == 0 && f.journals.isEmpty)
        }
    }

    @Test func changedDocumentCustomerOrItemDuringDiscoveryIsNeverAdopted() async throws {
        for kind in 0..<3 {
            let f = try BillingNativeWorkflowTests.Fixture()
            let preparation = try prepare(f, beforeDiscovery: {
                if kind == 0 { f.app.invoice.notes = "Changed while waiting" }
                if kind == 1 { f.app.customer.name = "Changed customer" }
                if kind == 2 { f.app.item.unitPrice = 250 }
            })
            await #expect(throws: QuickBooksBillingWorkflowError.changed) { try await preparation.makeWorkflow(lifecycle: f.app.owner) }
            #expect(f.writes == 0 && f.app.owner.activeID == nil && f.journals.isEmpty)
        }
    }

    @Test func cancelledNavigationOrRevokedAccessDuringDiscoveryCannotCreateOwner() async throws {
        for revoked in [false, true] {
            let f = try BillingNativeWorkflowTests.Fixture()
            var current = true
            let preparation = try prepare(f, current: { current }, beforeDiscovery: {
                if revoked { f.app.authorized = false } else { current = false }
            })
            await #expect(throws: (any Error).self) { try await preparation.makeWorkflow(lifecycle: f.app.owner) }
            #expect(f.writes == 0 && f.app.owner.activeID == nil)
        }
    }

    @Test func offlineAndOldServerKeepOriginalDraftAndNeverFallbackToIntuit() async throws {
        for error in [URLError(.notConnectedToInternet) as Error, GunnAireBackendError.server(statusCode: 404, message: "old") as Error] {
            let f = try BillingNativeWorkflowTests.Fixture(), original = f.app.invoice.catalogSnapshotJSON
            let preparation = try prepare(f, discoverError: error)
            await #expect(throws: (any Error).self) { try await preparation.makeWorkflow(lifecycle: f.app.owner) }
            #expect(f.app.invoice.catalogSnapshotJSON == original && f.app.invoice.quickBooksID == nil)
            #expect(f.writes == 0 && f.app.requests.isEmpty && f.journals.isEmpty)
        }
    }

    @Test func replacementGrantAfterDiscoveryCannotPublishOriginalUnderNewAuthorization() async throws {
        let f = try BillingNativeWorkflowTests.Fixture()
        let flow = try await prepare(f).makeWorkflow(lifecycle: f.app.owner, billingJournal: f.app.billingJournal)
        f.epoch = String(repeating: "b", count: 64)
        await #expect(throws: BillingPublicationError.reviewRequired) { try await flow.execute() }
        #expect(f.writes == 0 && f.journals.isEmpty)
        f.finish(flow)
    }

    @Test func businessSessionLostReplyRecoversOriginalWithoutSecondInvoice() async throws {
        let f = try BillingNativeWorkflowTests.Fixture(); f.failReply = true
        let first = try await prepare(f).makeWorkflow(lifecycle: f.app.owner, billingJournal: f.app.billingJournal)
        await #expect(throws: (any Error).self) { try await first.execute() }
        f.finish(first); f.failReply = false
        let second = try await prepare(f).makeWorkflow(lifecycle: f.app.owner, billingJournal: f.app.billingJournal)
        #expect(try await second.execute().recovered)
        #expect(f.writes == 1 && f.app.invoice.quickBooksID == "D1" && f.app.requests.isEmpty)
        f.finish(second)
    }

    @Test func fieldCreatedItemWaitsForReviewThenPublishesItsOriginalSoldPrice() async throws {
        let f = try BillingNativeWorkflowTests.Fixture()
        let sold = f.app.invoice.catalogSnapshotJSON
        f.app.item.markForPricebookReview(createdByEmail: "technician@example.invalid")
        let pending = try prepare(f)
        await #expect(throws: (any Error).self) { try await pending.makeWorkflow(lifecycle: f.app.owner) }
        #expect(f.writes == 0 && f.app.invoice.catalogSnapshotJSON == sold)
        // The office has approved and mapped this item. A later catalog price
        // does not replace the technician's saved sold price in the invoice.
        f.app.item.pricebookReviewStatus = .approved
        f.app.item.pricebookReviewedByEmail = "office@example.invalid"
        f.app.item.unitPrice = 250
        let approved = try await prepare(f).makeWorkflow(lifecycle: f.app.owner, billingJournal: f.app.billingJournal)
        _ = try await approved.execute()
        #expect(f.request?.document.Line.first?.SalesItemLineDetail.UnitPrice == 190)
        #expect(f.app.invoice.catalogSnapshotJSON == sold && f.writes == 1)
        f.finish(approved)
    }
}
