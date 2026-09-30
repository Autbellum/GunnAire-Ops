import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor
struct QuickBooksPublicationAccessTests {
    @MainActor private struct Fixture {
        let item: Item
        let invoice: Invoice
        let estimate: Estimate

        init() {
            let customer = Customer(quickBooksID: "C1", name: "Synthetic customer", email: "fixture@example.invalid")
            item = Item(quickBooksID: "I1", name: "Diagnostic", unitPrice: 190)
            let snapshot = CatalogLineItemSnapshot.encoded(from: [item])
            invoice = Invoice(customer: customer, catalogSnapshotJSON: snapshot, amount: 190)
            estimate = Estimate(customer: customer, catalogSnapshotJSON: snapshot, amount: 190)
        }
    }

    @Test func invoiceRevalidatesAccessAfterPreparingLinesOffMain() async throws {
        let fixture = Fixture()
        var validations = 0
        await #expect(throws: QuickBooksBillingWorkflowError.accessDenied) {
            try await QuickBooksInvoicePublicationRecovery.publicationInputsAsync(
                for: fixture.invoice, catalogItems: [fixture.item], payments: [], validateCurrent: {
                    validations += 1
                    if validations > 1 { throw QuickBooksBillingWorkflowError.accessDenied }
                })
        }
        #expect(validations == 2)
    }

    @Test func estimateRevalidatesAccessAfterPreparingLinesOffMain() async throws {
        let fixture = Fixture()
        var validations = 0
        await #expect(throws: QuickBooksBillingWorkflowError.accessDenied) {
            try await QuickBooksEstimatePublicationRecovery.publicationInputsAsync(
                for: fixture.estimate, catalogItems: [fixture.item], validateCurrent: {
                    validations += 1
                    if validations > 1 { throw QuickBooksBillingWorkflowError.accessDenied }
                })
        }
        #expect(validations == 2)
    }

    @Test func unchangedWorkspaceProducesBothDocumentsAfterRevalidation() async throws {
        let fixture = Fixture()
        var validations = 0
        let invoice = try await QuickBooksInvoicePublicationRecovery.publicationInputsAsync(
            for: fixture.invoice, catalogItems: [fixture.item], payments: [], validateCurrent: { validations += 1 })
        let estimate = try await QuickBooksEstimatePublicationRecovery.publicationInputsAsync(
            for: fixture.estimate, catalogItems: [fixture.item], validateCurrent: { validations += 1 })
        #expect(validations == 4)
        #expect(invoice.customerRef.value == "C1")
        #expect(estimate.customerRef.value == "C1")
        #expect(invoice.lines.count == 1)
        #expect(estimate.lines.count == 1)
        #expect(invoice.lines.first?.Amount == 190)
        #expect(estimate.lines.first?.Amount == 190)
    }

    @Test func automaticRecoveryIncludesSavedEstimatesAndInvoicesButSkipsConfirmedDocuments() {
        let fixture = Fixture()
        let pending = AutomaticOutboundSync.pendingDocumentKeys(
            invoices: [fixture.invoice], estimates: [fixture.estimate])
        #expect(pending == [.estimate(fixture.estimate.id), .invoice(fixture.invoice.id)])

        fixture.estimate.quickBooksID = "E1"
        fixture.invoice.quickBooksSyncStatus = "synced"
        #expect(AutomaticOutboundSync.pendingDocumentKeys(
            invoices: [fixture.invoice], estimates: [fixture.estimate]).isEmpty)
    }

    @Test func automaticRecoveryIncludesUnlinkedCustomerWithoutRepublishingLinkedCustomer() {
        let unlinked = Customer(name: "Saved local customer")
        let linked = Customer(quickBooksID: "C2", name: "Already linked")
        #expect(AutomaticOutboundSync.pendingCustomerKeys([unlinked, linked]) == [.customer(unlinked.id)])
        unlinked.quickBooksID = "C3"
        #expect(AutomaticOutboundSync.pendingCustomerKeys([unlinked, linked]).isEmpty)
    }

    @Test func oneRejectedDraftDoesNotPauseOtherAutomaticPublications() {
        #expect(!AutomaticOutboundSync.shouldPauseAfterFailure(QuickBooksBillingWorkflowError.changed))
        #expect(!AutomaticOutboundSync.shouldPauseAfterFailure(SharedBillingConnectionError.updateRequired))
        #expect(AutomaticOutboundSync.shouldPauseAfterFailure(URLError(.notConnectedToInternet)))
        #expect(AutomaticOutboundSync.shouldPauseAfterFailure(SharedBillingConnectionError.unavailable))
    }

    @Test func pendingCustomerScanAdvancesPastTheFirstHundredRecords() throws {
        let schema = GunnAireModelSchema.schema
        let context = ModelContext(try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
        for index in 0..<105 {
            context.insert(Customer(name: String(format: "Customer %03d", index)))
        }
        try context.save()
        let descriptor = FetchDescriptor<Customer>(sortBy: [SortDescriptor(\.name)])
        var offset = 0
        let first = try AutomaticOutboundSync.nextPage(descriptor, context: context, offset: &offset)
        let second = try AutomaticOutboundSync.nextPage(descriptor, context: context, offset: &offset)
        #expect(first.count == 100)
        #expect(second.count == 5)
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        #expect(offset == 0)
    }
}
