import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksCustomerEmailWorkflowTests {
    @MainActor private final class Fixture {
        let context: ModelContext
        let customer: Customer
        let estimate: Estimate
        let invoice: Invoice
        var allowed = true
        var requests: [URLRequest] = []
        var beforeRead: (() -> Void)?
        var beforePostResponse: (() -> Void)?
        lazy var api = QuickBooksDataAPI(testTokens: .init(accessToken: "synthetic-customer-email", expiration: .distantFuture),
            realmID: "synthetic-customer-email", environment: "sandbox",
            emailJournal: .init(directory: nil, memoryOnly: true)) { [unowned self] request in
                requests.append(request)
                let isPost = request.httpMethod == "POST"
                if isPost { beforePostResponse?() } else { beforeRead?() }
                let kind = request.url?.path.contains("/estimate/") == true ? "Estimate" : "Invoice"
                let data = try JSONSerialization.data(withJSONObject: [kind: ["Id": "42", "CustomerRef": ["value": "C1"],
                    "TotalAmt": 10, "BillEmail": ["Address": "fixture@example.invalid"],
                    "EmailStatus": isPost ? "EmailSent" : "NotSet"]])
                let url = try #require(request.url)
                let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (data, response)
            }

        init() throws {
            let schema = GunnAireModelSchema.schema
            context = ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ]))
            customer = Customer(quickBooksID: "C1", name: "Synthetic consent fixture", email: "fixture@example.invalid")
            estimate = Estimate(customer: customer, quickBooksID: "42", amount: 10)
            invoice = Invoice(customer: customer, quickBooksID: "42", amount: 10)
            context.insert(customer); context.insert(estimate); context.insert(invoice); try context.save()
        }

        func flow(invoice: Bool = false, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> QuickBooksCustomerEmailWorkflow {
            try QuickBooksCustomerEmailWorkflow(context: context, document: invoice ? .invoice(self.invoice) : .estimate(estimate),
                recipient: "fixture@example.invalid", validateAccess: {
                    if !self.allowed { throw GmailComposeError.access }
                }, save: save)
        }

        func send(_ workflow: QuickBooksCustomerEmailWorkflow, invoice: Bool = false) async -> Result<Void, Error> {
            await withCheckedContinuation { continuation in
                if invoice {
                    api.sendInvoice(id: "42", to: workflow.recipient, expectedCustomerID: workflow.quickBooksCustomerID,
                        validateSend: { try workflow.validateSend() }) { continuation.resume(returning: $0.map { _ in () }) }
                } else {
                    api.sendEstimate(id: "42", to: workflow.recipient, expectedCustomerID: workflow.quickBooksCustomerID,
                        validateSend: { try workflow.validateSend() }) { continuation.resume(returning: $0.map { _ in () }) }
                }
            }
        }
        func history() throws -> [CustomerCommunication] { try context.fetch(FetchDescriptor<CustomerCommunication>()) }
        var posts: Int { requests.filter { $0.httpMethod == "POST" }.count }
    }

    @Test func successfulAcceptanceSavesHistoryAndExplicitDeliveryLimitForBothDocuments() async throws {
        for invoice in [false, true] {
            let fixture = try Fixture(); let flow = try fixture.flow(invoice: invoice)
            try flow.prepare()
            #expect(try fixture.history().first?.deliveryStatus == "pending")
            let message = flow.finish(await fixture.send(flow, invoice: invoice))
            #expect(fixture.posts == 1)
            let record = try #require(fixture.history().first)
            #expect(record.deliveryStatus == "sent")
            #expect(record.consentSnapshot?.allowsTransactionalEmail == true)
            #expect(record.customer === fixture.customer)
            #expect(record.invoiceID == (invoice ? fixture.invoice.id : nil))
            #expect(record.estimateID == (invoice ? nil : fixture.estimate.id))
            #expect(message.contains("Recipient delivery is not verified"))
            #expect((invoice ? fixture.invoice.status : fixture.estimate.status) == "sent")
        }
    }

    @Test func declinedConsentSavesSuppressedHistoryWithoutTransport() throws {
        let fixture = try Fixture(); fixture.customer.allowsTransactionalEmail = false
        let flow = try fixture.flow()
        #expect(throws: GmailComposeError.consent) { try flow.prepare() }
        #expect(try fixture.history().first?.deliveryStatus == "suppressed")
        #expect(fixture.requests.isEmpty)
    }

    @Test func deniedEligibilityIsAuditedBeforeDocumentPreparation() throws {
        let fixture = try Fixture(); fixture.customer.allowsTransactionalEmail = false
        let flow = try fixture.flow()
        #expect(throws: GmailComposeError.consent) { try flow.checkEligibilityAndRecordSuppression() }
        #expect(try fixture.history().first?.deliveryStatus == "suppressed")
        #expect(fixture.requests.isEmpty)
    }

    @Test func deletedPendingHistoryIsRejectedWithoutReadingInvalidatedModel() throws {
        let fixture = try Fixture(); let flow = try fixture.flow(); try flow.prepare()
        let record = try #require(fixture.history().first)
        fixture.context.delete(record); try fixture.context.save()
        #expect(throws: GmailComposeError.changed) { try flow.validateSend() }
        let message = flow.finish(.failure(QuickBooksDocumentEmailError.reviewRequired))
        #expect(message.contains("Local history was not updated"))
        #expect(try fixture.history().isEmpty)
        #expect(fixture.estimate.status != "sent")
    }

    @Test func pendingHistorySaveFailurePreventsTransport() throws {
        let fixture = try Fixture()
        let flow = try fixture.flow(save: { _ in throw GmailComposeError.save })
        #expect(throws: GmailComposeError.save) { try flow.prepare() }
        #expect(throws: QuickBooksDocumentEmailError.busy) { try flow.validateSend() }
        #expect(try fixture.history().isEmpty)
        #expect(fixture.requests.isEmpty)
    }

    @Test func consentAndAccessRevocationDuringProviderReadPreventPost() async throws {
        for revokeConsent in [false, true] {
            let fixture = try Fixture(); let flow = try fixture.flow(); try flow.prepare()
            fixture.beforeRead = {
                if revokeConsent { fixture.customer.allowsTransactionalEmail = false }
                else { fixture.allowed = false }
            }
            let result = await fixture.send(flow)
            if case .success = result { Issue.record("A revoked action must not send") }
            let message = flow.finish(result)
            #expect(fixture.posts == 0)
            #expect(try fixture.history().first?.deliveryStatus == "pending")
            #expect(message.contains("original record changed"))
            #expect(fixture.estimate.status != "sent")
        }
    }

    @Test func replacingCustomerDuringSendCannotStampReplacementOrOriginalDocument() async throws {
        let fixture = try Fixture(); let flow = try fixture.flow(); try flow.prepare()
        let replacement = Customer(id: fixture.customer.id, quickBooksID: "C1", name: "Replacement", email: "fixture@example.invalid")
        fixture.beforePostResponse = {
            fixture.context.insert(replacement)
            fixture.estimate.customer = replacement
        }
        let message = flow.finish(await fixture.send(flow))
        #expect(fixture.posts == 1)
        #expect(fixture.estimate.status != "sent")
        let history = try #require(fixture.history().first)
        #expect(history.customer === fixture.customer)
        #expect(history.deliveryStatus == "pending")
        #expect(message.contains("may have accepted"))
    }

    @Test func changedSavedDocumentDuringSendLeavesHistoryPending() async throws {
        let fixture = try Fixture(); let flow = try fixture.flow(invoice: true); try flow.prepare()
        fixture.beforePostResponse = { fixture.invoice.dueDate = Date(timeIntervalSince1970: 2_000_000_000) }
        let message = flow.finish(await fixture.send(flow, invoice: true))
        #expect(fixture.posts == 1)
        #expect(fixture.invoice.status != "sent")
        #expect(try fixture.history().first?.deliveryStatus == "pending")
        #expect(message.contains("may have accepted"))
    }

    @Test func uncertaintyAndReconciliationHaveDistinctHistoryWithoutDeliveryClaim() throws {
        for reconciled in [false, true] {
            let fixture = try Fixture(); let flow = try fixture.flow(); try flow.prepare()
            let message = flow.finish(.failure(reconciled ? QuickBooksDocumentEmailError.reconciled : .reviewRequired))
            #expect(try fixture.history().first?.deliveryStatus == (reconciled ? "sent" : "unconfirmed"))
            #expect(message.contains("Another copy was not sent"))
            #expect(fixture.requests.isEmpty)
        }
    }

    @Test func failedConfirmationSaveRestoresOnlyOwnedStatus() async throws {
        let fixture = try Fixture(); var saves = 0
        let flow = try fixture.flow(save: { context in
            saves += 1
            if saves > 1 { throw GmailComposeError.save }
            try context.save()
        })
        try flow.prepare()
        let originalStatus = fixture.estimate.status
        let message = flow.finish(await fixture.send(flow))
        #expect(fixture.posts == 1)
        #expect(try fixture.history().first?.deliveryStatus == "pending")
        #expect(fixture.estimate.status == originalStatus)
        #expect(message.contains("could not be saved locally"))
    }

    @Test func recipientAndAmbiguousCustomerMappingFailClosed() throws {
        let fixture = try Fixture()
        #expect(throws: QuickBooksDocumentEmailError.recipientRequired) {
            try QuickBooksCustomerEmailWorkflow(context: fixture.context, document: .estimate(fixture.estimate),
                recipient: "another@example.invalid", validateAccess: {})
        }
        fixture.context.insert(Customer(quickBooksID: "C1", name: "Ambiguous", email: "other@example.invalid"))
        #expect(throws: QuickBooksBillingWorkflowError.customerConflict) { try fixture.flow() }
        #expect(fixture.requests.isEmpty)
        #expect(try fixture.history().isEmpty)
    }
}
