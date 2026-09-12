import Foundation
import Testing
@testable import GunnAire_Ops

@MainActor struct ReceiptTransactionPickerTests {
    private func choice(_ id: String = "opaque-100", type: QuickBooksAttachableEntityType = .invoice,
                        name: String? = "Service customer", number: String? = "INV-42",
                        amount: Double = 189, date: String? = "2026-09-09") -> ReceiptTransactionChoice {
        .init(type: type, providerID: id, documentNumber: number, partyName: name,
              amount: amount, transactionDate: date)
    }

    @Test func normalLabelsUseBusinessDetailsNotProviderIDs() {
        let row = choice()
        #expect(row.title == "Invoice #INV-42")
        #expect(row.party == "Service customer")
        #expect(row.formattedAmount.contains("189"))
        #expect(row.formattedDate != "Date unavailable")
        #expect(![row.title, row.party, row.formattedAmount, row.formattedDate].joined().contains(row.providerID))
        #expect(row.matches(search: "service"))
        #expect(row.matches(search: "inv-42"))
        #expect(row.matches(search: "189"))
        #expect(!row.matches(search: "opaque-100"))
        #expect(row.matches(search: "  "))
    }

    @Test func missingMetadataNeverFallsBackToAnOpaqueIDOrInvalidDate() {
        let row = choice("exact-id", name: "  ", number: " ", date: "2026-02-30")
        #expect(row.title == "Invoice")
        #expect(row.party == "Name unavailable")
        #expect(row.formattedDate == "Date unavailable")
        #expect(choice(date: "2026-09-09garbage").formattedDate == "Date unavailable")
        #expect(choice(date: nil).formattedDate == "Date unavailable")
    }

    @Test func allSixTypesRemainDistinctEvenWithTheSameIDAndDisplayDetails() {
        let rows = QuickBooksAttachableEntityType.allCases.map { choice("100", type: $0) }
        #expect(rows.count == 6 && Set(rows.map(\.id)).count == 6)
        #expect(rows.first(where: { $0.type == .salesReceipt })?.title == "Sales Receipt #INV-42")
        #expect(rows.first(where: { $0.type == .purchase })?.title == "Expense #INV-42")
        for row in rows {
            let browser = ReceiptTransactionBrowser()
            browser.load(type: row.type, checkAccess: {}) { _, complete in complete(.success([row])) }
            #expect(browser.select(row) == row)
        }
    }

    @Test func browsingAnotherTypeDoesNotChangeTheCommittedOriginalAndCancelRejectsLateResults() {
        let original = choice("invoice-original")
        var committed = original
        let browser = ReceiptTransactionBrowser()
        var reply: ReceiptTransactionBrowser.Completion?
        browser.load(type: .estimate, checkAccess: {}) { type, complete in
            #expect(type == .estimate); reply = complete
        }
        #expect(browser.isLoading)
        browser.cancel()
        let alternate = choice("estimate-other", type: .estimate)
        reply?(.success([alternate]))
        if let selected = browser.select(alternate) { committed = selected }
        #expect(committed == original)
        #expect(browser.choices.isEmpty && !browser.isLoading)
    }

    @Test func aPreviousCategoryReplyCannotReplaceTheCurrentRequest() {
        let browser = ReceiptTransactionBrowser()
        var old: ReceiptTransactionBrowser.Completion?
        browser.load(type: .invoice, checkAccess: {}) { _, complete in old = complete }
        let current = choice("bill-current", type: .bill)
        browser.load(type: .bill, checkAccess: {}) { _, complete in complete(.success([current])) }
        old?(.success([choice()]))
        #expect(browser.type == .bill && browser.choices == [current])
        #expect(browser.select(current) == current)
        #expect(browser.select(choice()) == nil)
    }

    @Test func revokedAccessBeforeResponseOrSelectionClearsAllResults() {
        for revokeBeforeReply in [false, true] {
            var active = true
            let browser = ReceiptTransactionBrowser()
            var reply: ReceiptTransactionBrowser.Completion?
            browser.load(type: .invoice, checkAccess: {
                if !active { throw QBODocumentError.access }
            }) { _, complete in reply = complete }
            if revokeBeforeReply { active = false }
            reply?(.success([choice()]))
            active = false
            #expect(browser.select(choice()) == nil)
            #expect(browser.choices.isEmpty && !browser.isLoading)
            #expect(browser.message?.contains("access changed") == true)
        }
    }

    @Test func unavailableAccessNeverLoadsOrShowsProviderMetadata() {
        let browser = ReceiptTransactionBrowser()
        var calls = 0
        browser.load(type: .invoice, checkAccess: { throw QBODocumentError.access }) { _, _ in calls += 1 }
        #expect(calls == 0 && !browser.isLoading && browser.choices.isEmpty)
        #expect(browser.select(choice()) == nil)
    }

    @Test func ambiguousEmptyWrongTypeAndNonfiniteRowsCannotBeSelected() {
        let browser = ReceiptTransactionBrowser()
        let safe = choice("safe"), first = choice("collision"), other = choice(" collision ", name: "Another customer")
        let invalid = [choice(" "), choice("wrong-type", type: .estimate), choice("bad-total", amount: .nan)]
        browser.load(type: .invoice, checkAccess: {}) { _, complete in
            complete(.success([safe, first, other] + invalid))
        }
        #expect(browser.choices == [safe])
        #expect(browser.message?.contains("identity review") == true)
        #expect(browser.select(safe) == safe)
        for row in [first, other] + invalid { #expect(browser.select(row) == nil) }
        #expect(browser.select(choice("safe", name: "Forged display")) == nil)
    }

    @Test func failedRefreshDoesNotRetainOldChoicesOrExposeTechnicalErrors() {
        let browser = ReceiptTransactionBrowser()
        browser.load(type: .invoice, checkAccess: {}) { _, complete in complete(.success([choice()])) }
        browser.load(type: .invoice, checkAccess: {}) { _, complete in
            complete(.failure(NSError(domain: "secret-provider-body", code: 401)))
        }
        #expect(browser.choices.isEmpty && !browser.isLoading)
        #expect(browser.message?.contains("try again") == true)
        #expect(browser.message?.contains("secret-provider-body") == false)
        #expect(browser.select(choice()) == nil)
    }

    @Test func localJobSummaryKeepsTheOriginalLinkAndDoesNotGuessByCustomerOrAmount() {
        let customer = Customer(name: "Same customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let original = Invoice(serviceCallID: call.id, customer: customer, quickBooksID: "original", amount: 189)
        let newer = Invoice(serviceCallID: call.id, customer: customer, quickBooksID: "newer", amount: 189)
        call.linkedInvoiceID = original.id
        let row = ReceiptTransactionChoice.linked(to: call, invoices: [newer, original], estimates: [], payments: [])
        #expect(row?.providerID == "original" && row?.type == .invoice)
        #expect(row?.party == customer.name && row?.title == "Invoice")
        #expect(ReceiptTransactionChoice.linked(to: call, invoices: [newer], estimates: [], payments: []) == nil)
        let proposal = Estimate(customer: customer, quickBooksID: "estimate", amount: 189)
        proposal.scheduledServiceCallID = UUID()
        call.linkedInvoiceID = nil; call.linkedEstimateID = proposal.id
        #expect(ReceiptTransactionChoice.linked(to: call, invoices: [], estimates: [proposal], payments: []) == nil)
        proposal.scheduledServiceCallID = call.id
        #expect(ReceiptTransactionChoice.linked(to: call, invoices: [], estimates: [proposal], payments: [])?.providerID == "estimate")
    }

    @Test func localTimestampUsesTheLocalCalendarDayWhileProviderDatesDoNotShift() {
        let customer = Customer(name: "Calendar customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let date = Date(timeIntervalSince1970: 3600)
        let invoice = Invoice(serviceCallID: call.id, customer: customer, quickBooksID: "original", createdAt: date)
        call.linkedInvoiceID = invoice.id
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .autoupdatingCurrent
        day.dateFormat = "yyyy-MM-dd"
        let row = ReceiptTransactionChoice.linked(to: call, invoices: [invoice], estimates: [], payments: [])
        #expect(row?.transactionDate == day.string(from: date))
        #expect(choice(date: "2026-09-09").transactionDate == "2026-09-09")
    }
}
