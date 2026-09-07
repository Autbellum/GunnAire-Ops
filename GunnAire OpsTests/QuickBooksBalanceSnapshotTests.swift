import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksBalanceSnapshotTests {
    private func fixture(balance: Double? = 300) throws -> (ModelContainer, ModelContext, Invoice) {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "C1", name: "Fixture Customer")
        let invoice = Invoice(customer: customer, quickBooksID: "I1",
            quickBooksBalanceDue: balance, amount: 500, status: "partial")
        invoice.quickBooksSyncStatus = "synced"
        context.insert(customer)
        context.insert(invoice)
        try context.save()
        return (container, context, invoice)
    }

    private func remoteInvoice(balance: Any? = 300, total: Any = 500) throws -> QuickBooksInvoice {
        var object: [String: Any] = [
            "Id": "I1", "CustomerRef": ["value": "C1"], "TotalAmt": total, "TxnDate": "2026-09-01"
        ]
        if let balance { object["Balance"] = balance }
        return try JSONDecoder().decode(QuickBooksInvoice.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    private func remotePayment(id: String = "P1", amount: Double = 100, method: String = "Credit Card") throws -> QuickBooksPayment {
        let object: [String: Any] = [
            "Id": id, "CustomerRef": ["value": "C1"], "TotalAmt": amount,
            "TxnDate": "2026-09-01", "PaymentMethodRef": ["value": "M1", "name": method],
            "Line": [["Amount": amount, "LinkedTxn": [["TxnId": "I1", "TxnType": "Invoice"]]]]
        ]
        return try JSONDecoder().decode(QuickBooksPayment.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    private func importRecords(_ context: ModelContext, invoices: [QuickBooksInvoice] = [],
                               payments: [QuickBooksPayment] = []) throws {
        do {
            try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
                invoices: invoices, payments: payments, vendors: [], into: context)
        } catch is QuickBooksBillingImportReview {
            // A partial outcome must preserve safe records and expose review.
        }
    }



    @Test func paymentQueryNeverSilentlyDropsRepeatedProviderIdentities() async throws {
        var count = 0
        let api = QuickBooksDataAPI(testTokens: QuickBooksOAuthTokens(accessToken: "fixture", expiration: .distantFuture),
            realmID: "fixture-realm", environment: Config.QuickBooks.environment) { request in
            count += 1
            let records: [[String: Any]] = count == 1
                ? (0..<QuickBooksQueryPagination.pageSize).map { ["Id": "P\($0)", "TotalAmt": 1] }
                : [["Id": "P0", "TotalAmt": 99]]
            let data = try JSONSerialization.data(withJSONObject: ["QueryResponse": ["Payment": records]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result: Result<[QuickBooksPayment], Error> = await withCheckedContinuation { continuation in
            api.fetchPayments { continuation.resume(returning: $0) }
        }
        #expect(count == 2)
        if case .failure(let error) = result {
            #expect(error is QuickBooksProviderResponseError)
        } else { Issue.record("A repeated ID must not silently choose the earlier payment amount") }
    }

    @Test func paymentQueryDoesNotReturnPartialSuccessAfterLaterPageFailure() async throws {
        var count = 0
        let api = QuickBooksDataAPI(testTokens: QuickBooksOAuthTokens(accessToken: "fixture", expiration: .distantFuture),
            realmID: "fixture-realm", environment: Config.QuickBooks.environment) { request in
            count += 1
            let records = (0..<QuickBooksQueryPagination.pageSize).map { ["Id": "P\($0)", "TotalAmt": "1"] }
            let data = count == 1
                ? try JSONSerialization.data(withJSONObject: ["QueryResponse": ["Payment": records]])
                : Data()
            return (data, HTTPURLResponse(url: request.url!, statusCode: count == 1 ? 200 : 503,
                httpVersion: nil, headerFields: nil)!)
        }
        let result: Result<[QuickBooksPayment], Error> = await withCheckedContinuation { continuation in
            api.fetchPayments { continuation.resume(returning: $0) }
        }
        #expect(count == 2)
        if case .success = result { Issue.record("An incomplete payment query returned success") }
    }

    @Test func paymentQueryReturnsEveryPageWhenIdentitiesAreUnique() async throws {
        var count = 0
        let api = QuickBooksDataAPI(testTokens: QuickBooksOAuthTokens(accessToken: "fixture", expiration: .distantFuture),
            realmID: "fixture-realm", environment: Config.QuickBooks.environment) { request in
            count += 1
            let records = count == 1
                ? (0..<QuickBooksQueryPagination.pageSize).map { ["Id": "P\($0)", "TotalAmt": "1"] }
                : [["Id": "FINAL", "TotalAmt": "2"]]
            let data = try JSONSerialization.data(withJSONObject: ["QueryResponse": ["Payment": records]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result: Result<[QuickBooksPayment], Error> = await withCheckedContinuation { continuation in
            api.fetchPayments { continuation.resume(returning: $0) }
        }
        let values = try result.get()
        #expect(count == 2)
        #expect(values.count == QuickBooksQueryPagination.pageSize + 1)
        #expect(values.last?.Id == "FINAL")
    }

    @Test func failedResourceCannotReimportStaleScreenRecords() {
        let success: Set<String> = ["payments"]
        #expect(QuickBooksSnapshotImportPolicy.records(["old invoice"], resource: "invoices", successfulResourceIDs: success).isEmpty)
        #expect(QuickBooksSnapshotImportPolicy.records(["fresh payment"], resource: "payments", successfulResourceIDs: success) == ["fresh payment"])
        #expect(QuickBooksSnapshotImportPolicy.records([String](), resource: "payments", successfulResourceIDs: success).isEmpty)
    }

    @Test func incompleteRefreshNeverAdvertisesPaidFromASavedZero() throws {
        let (container, context, invoice) = try fixture(balance: 0)
        defer { withExtendedLifetime(container) {} }
        invoice.status = "paid"
        try importRecords(context, payments: [remotePayment()])
        #expect(invoice.quickBooksBalanceDue == 0)
        #expect(!Invoice.isPaid(invoice, payments: []))
        #expect(Invoice.resolvedStatus(for: invoice, payments: []) == "review")
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: []) != nil)
    }

    @Test func freshZeroBalanceRemainsAuthoritativeWithoutPaymentHistory() throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        try importRecords(context, invoices: [remoteInvoice(balance: 0)])
        #expect(invoice.quickBooksBalanceDue == 0)
        #expect(Invoice.isPaid(invoice, payments: []))
        #expect(invoice.paymentCollectionBlockedMessage == nil)
    }

    @Test func missingBalanceOnNewInvoiceCannotInventACollectibleAmount() throws {
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        try importRecords(context, invoices: [remoteInvoice(balance: nil)])
        let invoice = try #require(context.fetch(FetchDescriptor<Invoice>()).first)
        #expect(invoice.quickBooksBalanceDue == nil)
        #expect(invoice.quickBooksLastSyncedAt == nil)
        #expect(!invoice.isReadyForPaymentCollection)
    }

    @Test func nativeCaptureAmountCannotBeOverwrittenByAccountingAllocation() throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let payment = Payment(invoice: invoice, quickBooksID: "P1", quickBooksChargeID: "CAPTURE1",
            amount: 200, method: "card", processor: OnsitePaymentProcessor.quickBooksPayments.rawValue)
        context.insert(payment)
        try context.save()
        try importRecords(context, invoices: [remoteInvoice()], payments: [remotePayment(amount: 100)])
        #expect(payment.amount == 200)
        #expect(payment.needsQuickBooksAttention)
        #expect(invoice.paymentCollectionBlockedMessage != nil)
    }

    @Test func balanceReviewBlocksReportCSVAndCustomerStatementUntilRefresh() throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        try importRecords(context, payments: [remotePayment()])
        let payments = try context.fetch(FetchDescriptor<Payment>())
        let report = BusinessReporting.snapshot(period: .currentMonth, serviceCalls: [], estimates: [],
            invoices: [invoice], payments: payments, timeEntries: [], technicians: [])
        #expect(report.billingIdentityReviewMessage != nil)
        #expect(!BusinessReportCSV.render(report).contains("Invoiced Revenue"))
        let statement = CustomerDocumentExporter.accountStatementSnapshot(for: invoice.customer,
            invoices: [invoice], payments: payments)
        #expect(statement.exportBlockingMessage != nil)
    }

    @Test(arguments: ["NaN", "-1", "Infinity"])
    func invalidTotalCannotOverwriteSavedFinancialValues(total: String) throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        #expect(throws: DecodingError.self) { try remoteInvoice(total: total) }
        #expect(invoice.amount == 500)
        #expect(invoice.quickBooksBalanceDue == 300)
        #expect(try context.fetch(FetchDescriptor<Invoice>()).count == 1)
    }

    @Test func missingTotalCannotDecodeAsAFreePaidInvoice() throws {
        let data = Data(#"{"Id":"I1","CustomerRef":{"value":"C1"},"Balance":0}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(QuickBooksInvoice.self, from: data)
        }
    }

    @Test func paymentSubsetDoesNotInventInvoiceBalanceOrFreshness() throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let earlier = Date(timeIntervalSince1970: 1_788_000_000)
        invoice.quickBooksLastSyncedAt = earlier
        try importRecords(context, payments: [remotePayment()])
        #expect(invoice.quickBooksBalanceDue == 300)
        #expect(invoice.status == "partial")
        #expect(invoice.quickBooksLastSyncedAt == earlier)
        #expect(invoice.needsQuickBooksAttention)
        #expect(invoice.paymentCollectionBlockedMessage != nil)
        #expect(try context.fetch(FetchDescriptor<Payment>()).count == 1)
    }

    @Test func missingInvoiceBalanceDoesNotReplaceLastKnownBalance() throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        try importRecords(context, invoices: [remoteInvoice(balance: nil)], payments: [remotePayment(amount: 500)])
        #expect(invoice.quickBooksBalanceDue == 300)
        #expect(invoice.needsQuickBooksAttention)
        #expect(invoice.paymentCollectionBlockedMessage != nil)
        #expect(invoice.status != "paid")
    }

    @Test(arguments: [-1.0, 600.0])
    func invalidInvoiceBalanceRequiresReview(balance: Double) throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        try importRecords(context, invoices: [remoteInvoice(balance: balance)])
        #expect(invoice.quickBooksBalanceDue == 300)
        #expect(invoice.needsQuickBooksAttention)
        #expect(invoice.paymentCollectionBlockedMessage != nil)
    }

    @Test func fullInvoiceRefreshResolvesPaymentOnlyReview() throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        try importRecords(context, payments: [remotePayment()])
        try importRecords(context, invoices: [remoteInvoice(balance: 200)], payments: [remotePayment()])
        #expect(invoice.quickBooksBalanceDue == 200)
        #expect(invoice.status == "partial")
        #expect(invoice.quickBooksSyncStatus == "synced")
        #expect(invoice.paymentCollectionBlockedMessage == nil)
        #expect(try context.fetch(FetchDescriptor<Payment>()).count == 1)
    }

    @Test func nativeACHKeepsItsRailAndCaptureTimestamp() throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let captureDate = Date(timeIntervalSince1970: 1_788_290_789)
        let payment = Payment(invoice: invoice, quickBooksID: "P1", quickBooksChargeID: "ECHECK-1",
            collectionAttemptID: UUID(), providerPaymentStatus: "PENDING",
            amount: 100, date: captureDate, method: "ach",
            processor: OnsitePaymentProcessor.quickBooksPayments.rawValue)
        context.insert(payment)
        try context.save()
        try importRecords(context, invoices: [remoteInvoice()], payments: [remotePayment(method: "ACH")])
        #expect(payment.method == "ach")
        #expect(payment.date == captureDate)
        #expect(payment.isProviderSettlementPending)
        #expect(payment.providerPaymentStatus == "PENDING")
    }

    @Test func paperCheckDoesNotBecomeAnElectronicBankPayment() throws {
        let (container, context, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        try importRecords(context, invoices: [remoteInvoice()], payments: [remotePayment(method: "Check")])
        let payment = try #require(context.fetch(FetchDescriptor<Payment>()).first)
        #expect(payment.method == "check")
        #expect(payment.backendCollectionMethod == "check")
    }

    @Test func duplicateLocalPaymentClaimsPreserveBothAmounts() throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let first = Payment(invoice: invoice, quickBooksID: "P1", amount: 50, method: "cash")
        let second = Payment(invoice: invoice, quickBooksID: "P1", amount: 75, method: "cash")
        context.insert(first)
        context.insert(second)
        try context.save()
        try importRecords(context, invoices: [remoteInvoice()], payments: [remotePayment()])
        #expect(first.amount == 50)
        #expect(second.amount == 75)
        #expect(try context.fetch(FetchDescriptor<Payment>()).count == 2)
        #expect(invoice.paymentCollectionBlockedMessage != nil)
    }

    @Test func duplicateRemotePaymentClaimsCannotSelectAnArbitraryAmount() throws {
        let (container, context, invoice) = try fixture()
        defer { withExtendedLifetime(container) {} }
        try importRecords(context, invoices: [remoteInvoice()],
            payments: [remotePayment(amount: 50), remotePayment(amount: 100)])
        #expect(try context.fetch(FetchDescriptor<Payment>()).isEmpty)
        #expect(invoice.paymentCollectionBlockedMessage != nil)
    }
}
