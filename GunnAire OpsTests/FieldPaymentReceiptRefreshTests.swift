import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct FieldPaymentReceiptRefreshTests {
    typealias Fixture = FieldPaymentReceiptTests.Fixture

    private func client(_ f: Fixture, snapshot: FieldPaymentReviewSnapshot,
                        duringRead: @escaping () throws -> Void = {}) throws -> FieldPaymentReviewClient {
        try .init(identity: f.identity, check: {}, request: { path in
            if path.contains("/context?") { return try JSONEncoder().encode(snapshot.scope) }
            try duringRead()
            return try JSONEncoder().encode(snapshot)
        }, now: { f.now })
    }

    @Test func ordinaryInvoiceWithoutSavedObservationMakesNoAdditionalRequest() async throws {
        let f = try Fixture()
        let message = try await FieldPaymentReceiptRefresh.ifSaved(invoice: f.invoice, check: {}, makeClient: { _ in
            Issue.record("Unexpected shared read for an invoice without a receipt"); throw URLError(.unsupportedURL)
        })
        #expect(message == nil)
        #expect(f.invoice.quickBooksBalanceDue == 100)
        #expect(f.invoice.quickBooksPaymentReviewJSON == nil)
    }

    @Test func actualBulkImportThenSharedCheckReconcilesOriginalInvoiceWithoutDuplicatingPayment() async throws {
        let f = try Fixture()
        try f.apply()
        let remote = try JSONDecoder().decode(QuickBooksInvoice.self, from: JSONSerialization.data(withJSONObject: [
            "Id": "D1", "CustomerRef": ["value": "C1"], "TotalAmt": 100, "Balance": 60,
            "SyncToken": "3", "TxnDate": "2026-09-08", "TxnTaxDetail": ["TotalTax": 0]]))
        let payment = try JSONDecoder().decode(QuickBooksPayment.self, from: JSONSerialization.data(withJSONObject: [
            "Id": "P1", "CustomerRef": ["value": "C1"], "TotalAmt": 40, "TxnDate": "2026-09-08",
            "Line": [["Amount": 40, "LinkedTxn": [["TxnId": "D1", "TxnType": "Invoice"]]]]]))
        try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [], invoices: [remote],
            payments: [payment], vendors: [], into: f.context)
        #expect(f.invoice.quickBooksReconciliationReviewMessage != nil)
        let observation = Date().addingTimeInterval(1)
        let snapshot = try f.snapshot(["observedAt": ISO8601DateFormatter().string(from: observation), "syncToken": "3"])
        for _ in 0..<2 {
            let pending = try await FieldPaymentReceiptRefresh.afterImport(context: f.context, invoiceIDs: ["D1"],
                check: {}, makeClient: { _ in
                    try .init(identity: f.identity, check: {}, request: { path in
                        try path.contains("/context?") ? JSONEncoder().encode(snapshot.scope) : JSONEncoder().encode(snapshot)
                    }, now: { observation })
                }, now: { observation })
            #expect(pending == 0)
        }
        #expect(f.invoice.quickBooksReconciliationReviewMessage == nil)
        #expect(f.invoice.quickBooksBalanceDue == 60)
        #expect(try f.context.fetchCount(FetchDescriptor<Payment>()) == 1)
        #expect(try f.context.fetchCount(FetchDescriptor<Invoice>()) == 1)
        let statement = CustomerAccountStatementPolicy.snapshot(customer: f.customer, invoices: [f.invoice],
            payments: try f.context.fetch(FetchDescriptor<Payment>()), asOf: nil, calendar: .current,
            now: observation.addingTimeInterval(5))
        #expect(statement.reviewMessages.isEmpty)
        #expect(statement.entries.first?.balanceDue == 60)
    }

    @Test func offlineFollowUpPreservesCommittedCaptureAndExistingHold() async throws {
        let f = try Fixture()
        try f.apply()
        let before = f.invoice.quickBooksPaymentReviewJSON
        let payment = Payment(invoice: f.invoice, quickBooksID: "P1", quickBooksChargeID: "capture-1", amount: 40)
        f.context.insert(payment); try f.context.save()
        let digest = try FieldPaymentReceiptReconciliation.paymentDigest(invoice: f.invoice, context: f.context)
        let message = try await FieldPaymentReceiptRefresh.ifSaved(invoice: f.invoice, check: {}, makeClient: { _ in
            try .init(identity: f.identity, check: {}, request: { _ in throw URLError(.notConnectedToInternet) })
        })
        #expect(message == FieldPaymentReceiptRefresh.pendingMessage)
        #expect(f.invoice.quickBooksPaymentReviewJSON == before)
        #expect(try FieldPaymentReceiptReconciliation.paymentDigest(invoice: f.invoice, context: f.context) == digest)
        #expect(f.invoice.paymentCollectionBlockedMessage != nil)
        #expect(payment.quickBooksID == "P1")
    }

    @Test func originalInvoicePaymentAndReceiptChangesDuringReadCannotBeAdopted() async throws {
        for mode in ["invoice", "payment", "receipt", "customer", "deleted"] {
            let f = try Fixture()
            try f.apply()
            let snapshot = try f.snapshot(["observedAt": ISO8601DateFormatter().string(from: f.now.addingTimeInterval(1))])
            let message = try await FieldPaymentReceiptRefresh.ifSaved(invoice: f.invoice, check: {}, makeClient: { _ in
                try client(f, snapshot: snapshot, duringRead: {
                    switch mode {
                    case "invoice": f.invoice.amount = 101
                    case "payment": f.context.insert(Payment(invoice: f.invoice, amount: 10))
                    case "receipt": f.invoice.quickBooksPaymentReviewJSON = "Other writer's evidence"
                    case "customer": f.customer.quickBooksID = "different-customer"
                    default: f.context.delete(f.invoice)
                    }
                })
            }, now: { f.now }, persist: { _ in Issue.record("Changed original was saved") })
            #expect(message == FieldPaymentReceiptRefresh.pendingMessage)
        }
    }

    @Test func revokedInitiatingRunPropagatesInsteadOfReportingOldWorkspaceSuccess() async throws {
        let f = try Fixture()
        try f.apply()
        var current = true
        let before = f.invoice.quickBooksPaymentReviewJSON
        let snapshot = try f.snapshot()
        await #expect(throws: WorkspaceProviderAccessError.unavailable) {
            try await FieldPaymentReceiptRefresh.ifSaved(invoice: f.invoice,
                check: { if !current { throw WorkspaceProviderAccessError.unavailable } }, makeClient: { _ in
                    try client(f, snapshot: snapshot, duringRead: { current = false })
                }, now: { f.now })
        }
        #expect(f.invoice.quickBooksPaymentReviewJSON == before)
    }

    @Test func failedReceiptSaveRetainsSuccessfulPaymentAndUnrelatedDraft() async throws {
        let f = try Fixture()
        try f.apply()
        let before = f.invoice.quickBooksPaymentReviewJSON
        let payment = Payment(invoice: f.invoice, quickBooksID: "P1", quickBooksChargeID: "capture", amount: 40)
        f.context.insert(payment); try f.context.save()
        f.customer.name = "Unsaved correction"
        let snapshot = try f.snapshot(["observedAt": ISO8601DateFormatter().string(from: f.now.addingTimeInterval(1))])
        let message = try await FieldPaymentReceiptRefresh.ifSaved(invoice: f.invoice, check: {},
            makeClient: { _ in try client(f, snapshot: snapshot) }, now: { f.now },
            persist: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        #expect(message == FieldPaymentReceiptRefresh.pendingMessage)
        #expect(f.invoice.quickBooksPaymentReviewJSON == before)
        #expect(f.customer.name == "Unsaved correction")
        #expect(payment.quickBooksID == "P1" && payment.amount == 40)
    }

    @Test func batchRefreshScopesOriginalInvoicesAndKeepsIndependentFailuresVisible() async throws {
        let f = try Fixture()
        try f.apply()
        let unrelated = Invoice(customer: f.customer, quickBooksID: "D2", amount: 10)
        f.context.insert(unrelated); try f.context.save()
        var reads = 0
        let snapshot = try f.snapshot(["hasOpenAttempt": true, "collectionLimitCents": 0,
            "observedAt": ISO8601DateFormatter().string(from: f.now.addingTimeInterval(1))])
        let pending = try await FieldPaymentReceiptRefresh.afterImport(context: f.context, invoiceIDs: ["D1", "D2"],
            check: {}, makeClient: { invoice in
                #expect(invoice === f.invoice); reads += 1
                return try client(f, snapshot: snapshot)
            }, now: { f.now })
        #expect(reads == 1 && pending == 1)
        #expect(f.invoice.paymentCollectionBlockedMessage?.contains("Another payment") == true)
        #expect(unrelated.quickBooksPaymentReviewJSON == nil)
        let ignored = try await FieldPaymentReceiptRefresh.afterImport(context: f.context, invoiceIDs: ["D2"],
            check: {}, makeClient: { _ in Issue.record("Untouched invoice was read"); throw URLError(.unsupportedURL) })
        #expect(ignored == 0)
    }
}
