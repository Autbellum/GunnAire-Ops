import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct BillingIdentityTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = GunnAireModelSchema.schema
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
    }

    private func remoteInvoice(id: String = "QBO-INV", customerID: String = "QBO-CUSTOMER",
                               marker: UUID? = nil, documentNumber: String = "1001") throws -> QuickBooksInvoice {
        var object: [String: Any] = [
            "Id": id, "DocNumber": documentNumber,
            "CustomerRef": ["value": customerID, "name": "Same Name"],
            "TotalAmt": 500, "Balance": 500, "TxnDate": "2026-09-01"
        ]
        if let marker { object["PrivateNote"] = "GunnAire Invoice ID: \(marker.uuidString)" }
        return try JSONDecoder().decode(QuickBooksInvoice.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func sameJobAndAmountDoNotHideIndependentInvoices() {
        let customer = Customer(name: "Same Name")
        let jobID = UUID()
        let first = Invoice(serviceCallID: jobID, customer: customer, amount: 500)
        let second = Invoice(serviceCallID: jobID, customer: customer, amount: 500)
        #expect(Set(Invoice.displayDeduplicated([first, second]).map(\.id)) == Set([first.id, second.id]))
    }

    @Test func invoiceLineageSelectsOnlyTheOriginalLocalRecord() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QBO-CUSTOMER", name: "Same Name")
        let original = Invoice(customer: customer, lineItemSummary: "Original scope", amount: 500)
        let independent = Invoice(customer: customer, lineItemSummary: "Second repair", amount: 500)
        let payment = Payment(invoice: independent, amount: 50, method: "cash")
        context.insert(customer)
        context.insert(original)
        context.insert(independent)
        context.insert(payment)
        try context.save()

        try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
            invoices: [remoteInvoice(marker: original.id)], payments: [], vendors: [], into: context)

        let stored = try context.fetch(FetchDescriptor<Invoice>())
        #expect(stored.count == 2)
        #expect(original.quickBooksID == "QBO-INV")
        #expect(independent.quickBooksID == nil)
        #expect(payment.invoice?.id == independent.id)
        #expect(independent.lineItemSummary == "Second repair")
    }

    @Test func duplicateQBOClaimsDoNotDeleteLocalBillingHistory() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QBO-CUSTOMER", name: "Same Name")
        let first = Invoice(customer: customer, quickBooksID: "QBO-INV", amount: 500)
        let second = Invoice(customer: customer, quickBooksID: "QBO-INV", amount: 500)
        let payment = Payment(invoice: second, amount: 50, method: "cash")
        context.insert(customer)
        context.insert(first)
        context.insert(second)
        context.insert(payment)
        try context.save()

        do {
            try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
                invoices: [remoteInvoice()], payments: [], vendors: [], into: context)
        } catch { /* The conflict must be reported without deleting either record. */ }

        #expect(try context.fetch(FetchDescriptor<Invoice>()).count == 2)
        #expect(payment.invoice?.id == second.id)
    }


    @Test func independentSameNameCustomersKeepTheirOriginalProviderIDs() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let original = Customer(quickBooksID: "OTHER-CUSTOMER", name: "Same Name")
        context.insert(original)
        try context.save()
        let remote = QuickBooksCustomer(Id: "QBO-CUSTOMER", DisplayName: "Same Name",
            PrimaryPhone: nil, PrimaryEmailAddr: nil, BillAddr: nil)
        try QuickBooksLocalSync.importSnapshot(customers: [remote], items: [], estimates: [],
            invoices: [], payments: [], vendors: [], into: context)
        #expect(original.quickBooksID == "OTHER-CUSTOMER")
        #expect(try context.fetch(FetchDescriptor<Customer>()).count == 2)
    }

    @Test func unmarkedRemoteInvoiceDoesNotClaimAnEqualLocalDraft() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QBO-CUSTOMER", name: "Same Name")
        let draft = Invoice(customer: customer, lineItemSummary: "1001", amount: 500)
        context.insert(customer)
        context.insert(draft)
        try context.save()
        let remote = try remoteInvoice()
        try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
            invoices: [remote], payments: [], vendors: [], into: context)
        try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
            invoices: [remote], payments: [], vendors: [], into: context)
        #expect(draft.quickBooksID == nil)
        #expect(try context.fetch(FetchDescriptor<Invoice>()).count == 2)
    }

    @Test func foreignCustomerMarkerIsRejectedWhileUnrelatedRecordsRefresh() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "ORIGINAL-CUSTOMER", name: "Same Name")
        let original = Invoice(customer: customer, amount: 500)
        context.insert(customer)
        context.insert(original)
        try context.save()
        #expect(throws: QuickBooksBillingImportReview.self) {
            try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
                invoices: [remoteInvoice(marker: original.id), remoteInvoice(id: "SAFE-INVOICE")],
                payments: [], vendors: [], into: context)
        }
        #expect(original.customer.id == customer.id)
        #expect(original.quickBooksID == nil)
        #expect(original.quickBooksIdentityReviewMessage != nil)
        #expect(!original.isReadyForPaymentCollection)
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: original, payments: []) != nil)
        #expect(try context.fetch(FetchDescriptor<Invoice>()).count == 2)
    }

    @Test func conflictingRemoteLineageCannotCreateDuplicateLocalUUIDs() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let marker = UUID()
        #expect(throws: QuickBooksBillingImportReview.self) {
            try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
                invoices: [remoteInvoice(id: "FIRST", marker: marker), remoteInvoice(id: "SECOND", marker: marker)],
                payments: [], vendors: [], into: context)
        }
        #expect(try context.fetch(FetchDescriptor<Invoice>()).isEmpty)
    }

    @Test func restoredRemoteInvoiceRetainsItsDurableLocalUUID() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let marker = UUID()
        let remote = try remoteInvoice(marker: marker)
        try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
            invoices: [remote], payments: [], vendors: [], into: context)
        try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
            invoices: [remote], payments: [], vendors: [], into: context)
        let stored = try context.fetch(FetchDescriptor<Invoice>())
        #expect(stored.count == 1)
        #expect(stored.first?.id == marker)
    }

    @Test func missingRemoteCustomerDoesNotCreateAnOwnerlessInvoice() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        #expect(throws: QuickBooksBillingImportReview.self) {
            try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
                invoices: [remoteInvoice(customerID: "")], payments: [], vendors: [], into: context)
        }
        #expect(try context.fetch(FetchDescriptor<Invoice>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Customer>()).isEmpty)
    }

    @Test func collectionRequiresExactOpaqueIDsAndMatchingCustomer() throws {
        let customer = Customer(quickBooksID: "QBO-CUSTOMER", name: "Same Name")
        let exact = Invoice(customer: customer, quickBooksID: " QBO-INV ", amount: 500)
        let otherCase = Invoice(customer: customer, quickBooksID: "qbo-inv", amount: 500)
        let foreign = Invoice(customer: Customer(quickBooksID: "OTHER", name: "Same Name"),
            quickBooksID: "QBO-INV", amount: 500)
        let remote = try remoteInvoice()
        #expect(QuickBooksTrackedPaymentPolicy.linkedLocalInvoice(for: remote, in: [exact]) === exact)
        #expect(QuickBooksTrackedPaymentPolicy.linkedLocalInvoice(for: remote, in: [otherCase]) == nil)
        #expect(QuickBooksTrackedPaymentPolicy.linkedLocalInvoice(for: remote, in: [foreign]) == nil)
        #expect(QuickBooksTrackedPaymentPolicy.linkedLocalInvoice(for: remote, in: [exact, foreign]) == nil)
    }

    @Test func replicaDisplayUsesRefreshedAccountingEvidenceNotPaidFlagRank() {
        let customer = Customer(quickBooksID: "QBO-CUSTOMER", name: "Same Name")
        let localID = UUID()
        let stale = Invoice(id: localID, customer: customer, amount: 500, status: "paid")
        let refreshed = Invoice(id: localID, customer: customer, quickBooksID: "QBO-INV",
            quickBooksBalanceDue: 500, amount: 500, status: "unpaid")
        refreshed.quickBooksLastSyncedAt = Date()
        let displayed = Invoice.displayDeduplicated([stale, refreshed])
        #expect(displayed.count == 1)
        #expect(displayed.first === refreshed)
        #expect(Invoice.outstandingBalance(for: displayed[0], payments: []) == 500)
    }

    @Test func exactJobLinksAndAttachmentsSurviveRepeatedInvoiceRefresh() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QBO-CUSTOMER", name: "Same Name")
        let call = ServiceCall(siteAddress: "Fixture Service Site", serviceLocationID: UUID(),
            type: .repair, scheduledDate: Date(), customer: customer)
        let original = Invoice(customer: customer, amount: 500)
        call.linkedInvoiceID = original.id
        let attachment = ServiceDocumentAttachment(customer: customer, serviceCallID: call.id,
            kind: .serviceReport, displayName: "Fixture.pdf", localFilePath: "/tmp/fixture-not-uploaded.pdf",
            contentType: "application/pdf", fileSizeBytes: 12)
        context.insert(customer)
        context.insert(call)
        context.insert(original)
        context.insert(attachment)
        try context.save()
        let remote = try remoteInvoice(marker: original.id)
        for _ in 0..<2 {
            try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
                invoices: [remote], payments: [], vendors: [], into: context)
        }
        #expect(original.serviceCallID == call.id)
        #expect(original.serviceLocationID == call.serviceLocationID)
        #expect(original.siteAddress == call.siteAddress)
        #expect(call.linkedInvoiceID == original.id)
        #expect(attachment.invoiceID == original.id)
        #expect(try context.fetch(FetchDescriptor<Invoice>()).count == 1)
    }

    @Test func paymentCustomerCannotBeReassignedThroughAnInvoiceReference() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let customer = Customer(quickBooksID: "QBO-CUSTOMER", name: "Same Name")
        let invoice = Invoice(customer: customer, quickBooksID: "QBO-INV", amount: 500)
        context.insert(customer)
        context.insert(invoice)
        try context.save()
        let payment = try JSONDecoder().decode(QuickBooksPayment.self, from: Data(#"""
        {"Id":"PAYMENT","CustomerRef":{"value":"OTHER"},"TotalAmt":50,
         "Line":[{"Amount":50,"LinkedTxn":[{"TxnId":"QBO-INV","TxnType":"Invoice"}]}]}
        """#.utf8))
        #expect(throws: QuickBooksBillingImportReview.self) {
            try QuickBooksLocalSync.importSnapshot(customers: [], items: [], estimates: [],
                invoices: [], payments: [payment], vendors: [], into: context)
        }
        #expect(try context.fetch(FetchDescriptor<Payment>()).isEmpty)
    }

    @Test func reportingCountsIndependentEqualInvoicesButWithholdsAmbiguousTotals() {
        let customer = Customer(name: "Report Fixture")
        let jobID = UUID()
        let first = Invoice(serviceCallID: jobID, customer: customer, amount: 500)
        let second = Invoice(serviceCallID: jobID, customer: customer, amount: 500)
        func report() -> BusinessReportSnapshot {
            BusinessReporting.snapshot(period: .currentMonth, serviceCalls: [], estimates: [],
                invoices: [first, second], payments: [], timeEntries: [], technicians: [])
        }
        let independent = report()
        #expect(independent.invoiceCount == 2)
        #expect(independent.invoicedRevenue == 1000)
        #expect(independent.billingIdentityReviewMessage == nil)
        first.quickBooksID = "DUPLICATE"
        second.quickBooksID = "DUPLICATE"
        let conflicting = report()
        #expect(conflicting.billingIdentityReviewMessage != nil)
        let csv = BusinessReportCSV.render(conflicting)
        #expect(csv.contains("Billing review required"))
        #expect(!csv.contains("Invoiced Revenue"))
        #expect(CustomerDocumentExporter.accountStatementSnapshot(
            for: customer, invoices: [first, second], payments: []).exportBlockingMessage != nil)
    }

    @Test func trackedCollectionNeverUsesDocumentNumberAsProviderID() throws {
        let customer = Customer(quickBooksID: "QBO-CUSTOMER", name: "Same Name")
        let unrelated = Invoice(customer: customer, quickBooksID: "1001", amount: 500)
        #expect(QuickBooksTrackedPaymentPolicy.linkedLocalInvoice(
            for: try remoteInvoice(), in: [unrelated]) == nil)
    }
}
