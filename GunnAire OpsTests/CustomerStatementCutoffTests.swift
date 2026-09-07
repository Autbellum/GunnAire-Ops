import Foundation
import PDFKit
import Testing
@testable import GunnAire_Ops

@MainActor
struct CustomerStatementCutoffTests {
    @Test func historicalSnapshotDoesNotUseTodaysAccountingBalanceOrLaterActivity() throws {
        let cutoff = Date(timeIntervalSince1970: 1_788_566_400)
        let customer = Customer(name: "Statement fixture")
        let invoice = Invoice(customer: customer, quickBooksID: "fixture-invoice",
            quickBooksBalanceDue: 0, quickBooksLastSyncedAt: cutoff.addingTimeInterval(86400),
            amount: 500, status: "paid", dueDate: cutoff.addingTimeInterval(-86400),
            createdAt: cutoff.addingTimeInterval(-86400 * 30))
        let before = Payment(invoice: invoice, amount: 100, date: cutoff.addingTimeInterval(-60))
        let after = Payment(invoice: invoice, amount: 400, date: cutoff.addingTimeInterval(60))
        let laterInvoice = Invoice(customer: customer, amount: 250, createdAt: cutoff.addingTimeInterval(1))
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice, laterInvoice], payments: [before, after], asOf: cutoff)
        #expect(snapshot.entries.count == 1)
        let entry = try #require(snapshot.entries.first)
        #expect(entry.invoiceID == invoice.id)
        #expect(entry.balanceDue == 400)
        #expect(entry.netRecordedPayments == 100)
        #expect(entry.paymentActivity.count == 1)
        #expect(!entry.usesQuickBooksBalance)
        #expect(entry.dueStatus != "Paid")
    }

    @Test func twoLegitimateLocalInvoicesWithSameDateAndAmountRemainSeparate() {
        let customer = Customer(name: "Same name")
        let other = Customer(name: "Same name")
        let issued = Date().addingTimeInterval(-86400)
        let first = Invoice(customer: customer, amount: 125, createdAt: issued)
        let second = Invoice(customer: customer, amount: 125, createdAt: issued)
        let unrelated = Invoice(customer: other, amount: 125, status: "paid", createdAt: issued)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [first, second, unrelated], payments: [])
        #expect(snapshot.openInvoiceCount == 2)
        #expect(snapshot.totalBalance == 250)
    }

    @Test func exactCutoffIncludesBoundaryButNotLaterSameDayRefundsOrPayments() throws {
        let cutoff = Date(timeIntervalSince1970: 1_788_610_000)
        let customer = Customer(name: "Cutoff")
        let invoice = Invoice(customer: customer, amount: 400, createdAt: cutoff)
        let atBoundary = Payment(invoice: invoice, amount: 125, date: cutoff)
        let after = Payment(invoice: invoice, amount: 50, date: cutoff.addingTimeInterval(0.001))
        let refund = Payment(invoice: invoice, amount: 25, date: cutoff.addingTimeInterval(1), isRefund: true)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [atBoundary, after, refund], asOf: cutoff)
        #expect(snapshot.asOf == cutoff)
        let entry = try #require(snapshot.entries.first)
        #expect(entry.balanceDue == 275)
        #expect(entry.paymentActivity.count == 1)
    }

    @Test func localPaidFlagDoesNotEraseHistoricalDebt() throws {
        let cutoff = Date(timeIntervalSince1970: 1_788_566_400)
        let customer = Customer(name: "Paid later")
        let invoice = Invoice(customer: customer, amount: 200, status: "paid",
            createdAt: cutoff.addingTimeInterval(-86400))
        let payment = Payment(invoice: invoice, amount: 200, date: cutoff.addingTimeInterval(1))
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [payment], asOf: cutoff)
        #expect(snapshot.totalBalance == 200)
        #expect(snapshot.entries.first?.dueStatus != "Paid")
        #expect(snapshot.exportBlockingMessage != nil)
    }

    @Test func historicalExportsRequireHistoryEvenWhenTheLatestCacheLooksPlausible() {
        let cutoff = Date(timeIntervalSince1970: 1_788_566_400)
        let customer = Customer(name: "History")
        let invoice = Invoice(customer: customer, quickBooksID: "qbo-fixture",
            quickBooksBalanceDue: 100, quickBooksLastSyncedAt: cutoff.addingTimeInterval(-60),
            amount: 100, createdAt: cutoff.addingTimeInterval(-86400))
        #expect(throws: (any Error).self) {
            try CustomerDocumentExporter.exportAccountStatement(customer: customer,
                invoices: [invoice], payments: [], asOf: cutoff)
        }
        invoice.quickBooksID = nil
        #expect(throws: (any Error).self) {
            try CustomerDocumentExporter.exportAccountStatement(customer: customer,
                invoices: [invoice], payments: [], asOf: cutoff)
        }
        // An empty projection is not proof that no invoices existed then.
        #expect(throws: (any Error).self) {
            try CustomerDocumentExporter.exportAccountStatement(customer: customer,
                invoices: [], payments: [], asOf: cutoff)
        }
    }

    @Test func currentSavedAccountingBalanceIsNotDoubleReducedByLocalPayments() throws {
        let now = Date()
        let customer = Customer(name: "Current")
        let invoice = Invoice(customer: customer, quickBooksID: "qbo-fixture",
            quickBooksBalanceDue: 75, quickBooksLastSyncedAt: now.addingTimeInterval(-300),
            amount: 100, createdAt: now.addingTimeInterval(-86400))
        let payment = Payment(invoice: invoice, amount: 25, date: now.addingTimeInterval(-60))
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [payment], now: now)
        #expect(snapshot.totalBalance == 75)
        #expect(snapshot.exportBlockingMessage == nil)
        #expect(snapshot.entries.first?.usesQuickBooksBalance == true)
        #expect(snapshot.balanceSourceSummary.contains("not a live"))
    }

    @Test func missingFutureAndNonfiniteAccountingBalancesCannotBecomeCustomerDebt() {
        let now = Date()
        let customer = Customer(name: "Unverified")
        let invoice = Invoice(customer: customer, quickBooksID: "qbo-fixture",
            amount: 100, createdAt: now.addingTimeInterval(-1))
        for balance: Double? in [nil, .nan, .infinity, -1, 0.001] {
            invoice.quickBooksBalanceDue = balance
            let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
                for: customer, invoices: [invoice], payments: [], now: now)
            #expect(snapshot.exportBlockingMessage != nil)
        }
        invoice.quickBooksBalanceDue = 100
        invoice.quickBooksLastSyncedAt = now.addingTimeInterval(1)
        #expect(CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [], now: now).exportBlockingMessage != nil)
    }

    @Test func currentUnexplainedPaidFlagRequiresReconciliation() {
        let customer = Customer(name: "Paid review")
        let invoice = Invoice(customer: customer, amount: 100, status: "paid")
        #expect(CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: []).exportBlockingMessage != nil)
        let fullPayment = Payment(invoice: invoice, amount: 100)
        let resolved = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [fullPayment])
        #expect(resolved.exportBlockingMessage == nil)
        #expect(resolved.openInvoiceCount == 0)
    }

    @Test func repeatedPaymentIdentitiesDoNotDoubleReduceTheBalance() {
        let customer = Customer(name: "Duplicate event")
        let invoice = Invoice(customer: customer, amount: 100)
        let payment = Payment(invoice: invoice, quickBooksID: "same-payment", amount: 25)
        let replica = Payment(invoice: invoice, quickBooksID: "same-payment", amount: 25, date: payment.date)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [payment, payment, replica])
        #expect(snapshot.totalBalance == 75)
        #expect(snapshot.entries.first?.paymentActivity.count == 1)
        #expect(snapshot.exportBlockingMessage == nil)
    }

    @Test func distinctPartialRefundsAgainstOneChargeRemainSeparate() {
        let customer = Customer(name: "Refunds")
        let invoice = Invoice(customer: customer, amount: 100)
        let payment = Payment(invoice: invoice, quickBooksChargeID: "original-charge", amount: 50)
        let first = Payment(invoice: invoice, quickBooksChargeID: "original-charge", amount: 10,
            isRefund: true, refundedPaymentID: payment.id)
        let second = Payment(invoice: invoice, quickBooksChargeID: "original-charge", amount: 10,
            isRefund: true, refundedPaymentID: payment.id)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [payment, first, second])
        #expect(snapshot.totalBalance == 70)
        #expect(snapshot.entries.first?.paymentActivity.count == 3)
        #expect(snapshot.exportBlockingMessage == nil)
    }

    @Test func contradictoryPaymentReplicasBlockExport() {
        let customer = Customer(name: "Conflict")
        let invoice = Invoice(customer: customer, amount: 100)
        let payment = Payment(invoice: invoice, quickBooksID: "same-payment", amount: 25)
        let changed = Payment(invoice: invoice, quickBooksID: "same-payment", amount: 35, date: payment.date)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [payment, changed])
        #expect(snapshot.exportBlockingMessage?.contains("Duplicate payment") == true)
        #expect(throws: (any Error).self) {
            try CustomerDocumentExporter.exportAccountStatement(customer: customer, snapshot: snapshot)
        }
    }

    @Test func identicalInvoiceReplicasCollectTheirPaymentAliasesOnce() {
        let customer = Customer(name: "Invoice replicas")
        let invoice = Invoice(customer: customer, quickBooksID: "shared-invoice", quickBooksBalanceDue: 75, amount: 100)
        let replica = Invoice(id: invoice.id, customer: customer, quickBooksID: "shared-invoice", quickBooksBalanceDue: 75,
            amount: 100, createdAt: invoice.createdAt)
        let payment = Payment(invoice: invoice, quickBooksID: "same-payment", amount: 25)
        let remote = Payment(invoice: replica, quickBooksID: "same-payment", amount: 25, date: payment.date)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice, replica], payments: [payment, remote])
        #expect(snapshot.totalBalance == 75)
        #expect(snapshot.openInvoiceCount == 1)
        #expect(snapshot.entries.first?.paymentActivity.count == 1)
        #expect(snapshot.exportBlockingMessage == nil)
        replica.amount = 110
        #expect(CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice, replica], payments: []).exportBlockingMessage != nil)
    }

    @Test func separateProgressInvoicesForOneJobAreNotHeuristicallyMerged() {
        let customer = Customer(name: "Progress draws")
        let jobID = UUID()
        let first = Invoice(serviceCallID: jobID, customer: customer, amount: 500)
        let second = Invoice(serviceCallID: jobID, customer: customer, amount: 500, createdAt: first.createdAt)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [first, second], payments: [])
        #expect(snapshot.openInvoiceCount == 2)
        #expect(snapshot.totalBalance == 1000)
    }

    @Test func invalidAmountsAreReviewItemsRatherThanSilentlyZeroBalances() {
        let customer = Customer(name: "Invalid amount")
        for invalid in [Double.nan, .infinity, -1, 0.001] {
            let invoice = Invoice(customer: customer, amount: invalid)
            #expect(CustomerDocumentExporter.accountStatementSnapshot(
                for: customer, invoices: [invoice], payments: []).exportBlockingMessage != nil)
            let valid = Invoice(customer: customer, amount: 100)
            let payment = Payment(invoice: valid, amount: invalid)
            #expect(CustomerDocumentExporter.accountStatementSnapshot(
                for: customer, invoices: [valid], payments: [payment]).exportBlockingMessage != nil)
        }
    }

    @Test func agingUsesCalendarDaysAcrossDaylightSavingChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let due = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7)))
        let cutoff = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9)))
        let customer = Customer(name: "DST")
        let invoice = Invoice(customer: customer, amount: 100, dueDate: due, createdAt: due)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [], asOf: cutoff, calendar: calendar)
        #expect(snapshot.entries.first?.daysPastDue == 2)
        #expect(snapshot.entries.first?.dueStatus == "Overdue by 2 days")
        #expect(snapshot.timeZoneIdentifier == "America/New_York")
    }

    @Test func snapshotCannotBeExportedForAnotherCustomer() {
        let customer = Customer(name: "Original")
        let invoice = Invoice(customer: customer, amount: 100)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [])
        #expect(throws: (any Error).self) {
            try CustomerDocumentExporter.exportAccountStatement(customer: Customer(name: "Other"), snapshot: snapshot)
        }
    }

    @Test func commercialInvoiceTotalsAreNotLimitedByPaymentDispatchCaps() {
        let customer = Customer(name: "Commercial statement")
        let invoice = Invoice(customer: customer, amount: 2_500_000.75)
        let payment = Payment(invoice: invoice, amount: 1_100_000.25)
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [payment])
        #expect(snapshot.totalBalance == 1_400_000.50)
        #expect(snapshot.exportBlockingMessage == nil)
    }

    @Test func extremeAggregateAmountsRequestReviewWithoutTrapping() {
        let customer = Customer(name: "Numeric range")
        let invoice = Invoice(customer: customer, amount: 100)
        let payments = (0..<1100).map { _ in Payment(invoice: invoice, amount: 90_000_000_000_000) }
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: payments)
        #expect(snapshot.exportBlockingMessage?.contains("numeric range") == true)
        #expect(snapshot.totalBalance.isFinite)
    }

    @Test func currentPdfPreservesSourceCutoffTimezoneAndPendingBankStatus() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 0, minute: 5)))
        let customer = Customer(name: "Statement QA Fixture", address: "101 Comfort Lane")
        let invoice = Invoice(siteAddress: "202 Service Street", customer: customer,
            quickBooksID: "fixture-accounting", quickBooksBalanceDue: 600,
            quickBooksLastSyncedAt: now.addingTimeInterval(-300), workType: .repair,
            amount: 1000, dueDate: now.addingTimeInterval(-86400 * 10),
            createdAt: now.addingTimeInterval(-86400 * 30))
        let payment = Payment(invoice: invoice, providerPaymentStatus: "PENDING",
            amount: 400, date: now.addingTimeInterval(-60), method: "ach")
        let snapshot = CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [invoice], payments: [payment], calendar: calendar, now: now)
        let url = try CustomerDocumentExporter.exportAccountStatement(customer: customer, snapshot: snapshot)
        let document = try #require(PDFDocument(url: url))
        let text = try #require(document.string)
        #expect(text.contains("$600.00"))
        #expect(text.contains("Activity Through"))
        // PDFKit can insert a text-extraction line break at the underscore;
        // rendered glyphs and the stored calendar must both preserve the zone.
        #expect(snapshot.timeZoneIdentifier == "America/New_York")
        #expect(text.replacingOccurrences(of: "\n", with: "").contains("America/New_York"))
        #expect(text.contains("Sep 7, 2026"))
        #expect(text.contains("Bank Payment Pending"))
        #expect(text.contains("not a live accounting refresh"))
        #expect(text.contains("Unapplied customer credits"))
        let invoicePage = try #require((0..<document.pageCount).compactMap { document.page(at: $0)?.string }
            .first { $0.contains("Invoice Total") })
        #expect(invoicePage.contains("Invoice " + String(invoice.id.uuidString.prefix(8)).uppercased()))
        #expect(invoicePage.contains("Bank Payment Pending"))
        for index in 0..<document.pageCount {
            let bounds = try #require(document.page(at: index)).bounds(for: .mediaBox)
            #expect(bounds.width == 612 && bounds.height == 792)
        }
        print("STATEMENT_PDF_FIXTURE=\(url.path)")
    }
}
