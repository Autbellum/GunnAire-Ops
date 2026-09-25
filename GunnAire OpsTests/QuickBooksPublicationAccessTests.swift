import Foundation
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
}
