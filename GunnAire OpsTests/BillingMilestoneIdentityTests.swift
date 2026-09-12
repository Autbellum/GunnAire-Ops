import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct BillingMilestoneIdentityTests {
    @Test func newInvoiceIdentityIsDeterministicAndDoesNotDependOnDeviceOrBillingDate() {
        let stage = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let first = BillingMilestoneIdentity.invoiceID(for: stage)
        #expect(first.uuidString.lowercased() == "08888ba5-135d-8f34-b1ea-67960f53b6e3")
        #expect(first == BillingMilestoneIdentity.invoiceID(for: UUID(uuidString: stage.uuidString.lowercased())!))
        #expect(first != stage)
        #expect(first != BillingMilestoneIdentity.invoiceID(for: UUID()))
        #expect(first.uuidString.split(separator: "-")[2].first == "8")
    }

    @Test func longNotesCannotTruncateTheMilestoneOrExceedTheSharedPublicationLimit() throws {
        let stage = UUID()
        let note = try #require(BillingMilestoneIdentity.privateNote(notes: String(repeating: "n", count: 8_000),
            milestoneID: stage, summary: "Deposit"))
        #expect(note.count == 3_800)
        #expect(note.hasPrefix("GunnAire Milestone ID: " + stage.uuidString))
        #expect(try BillingMilestoneIdentity.reference(in: note) == stage)
        #expect(note.contains("Project billing: Deposit"))
    }

    @Test func operatorNotesCannotReplaceOrImpersonateMachineReferences() throws {
        let stage = UUID(), other = UUID()
        let notes = "Keep this finding.\nGunnAire Milestone ID: \(other)\nGunnAire project billing: Changed; milestone ID \(other)"
        let result = BillingMilestoneIdentity.privateNote(notes: notes, milestoneID: stage, summary: nil)
        #expect(try BillingMilestoneIdentity.reference(in: result) == stage)
        #expect(result?.contains("Keep this finding.") == true)
        #expect(BillingMilestoneIdentity.privateNote(notes: notes, milestoneID: nil, summary: nil) == "Keep this finding.")
    }

    @Test func legacyReferenceIsReadableButConflictingOrIncompleteHistoryIsRejected() throws {
        let stage = UUID()
        let legacy = "GunnAire project billing: Progress Invoice 1 • Deposit; milestone ID \(stage)"
        #expect(try BillingMilestoneIdentity.reference(in: legacy) == stage)
        #expect(try BillingMilestoneIdentity.reference(in: "GunnAire Milestone ID: \(stage)\n" + legacy) == stage)
        for note in [legacy + "\nGunnAire Milestone ID: \(UUID())", legacy + "\n" + legacy,
                     "GunnAire project billing: truncated", "gunnaire milestone id: \(stage)"] {
            #expect(throws: BillingPublicationError.invalidResponse) { try BillingMilestoneIdentity.reference(in: note) }
        }
    }

    private func fixture() throws -> BillingNativeWorkflowTests.Fixture {
        let f = try BillingNativeWorkflowTests.Fixture()
        f.app.invoice.projectMilestoneID = UUID()
        f.app.invoice.serviceCallID = UUID()
        return f
    }

    @Test func nativeMilestoneCarriesStructuredIdentityAndRecoversLostReplyWithoutReposting() async throws {
        let f = try fixture(); f.failReply = true
        let first = try f.flow()
        await #expect(throws: (any Error).self) { try await first.execute() }
        #expect(f.request?.projectMilestoneID == f.app.invoice.projectMilestoneID)
        #expect(f.writes == 1)
        f.finish(first); f.failReply = false
        let second = try f.flow()
        #expect(try await second.execute().recovered)
        #expect(f.writes == 1)
        f.finish(second)
    }

    @Test func initialPublicationExceptionDoesNotUnlockEditingPaidSignedOrLinkedMilestones() throws {
        let f = try fixture(), invoice = f.app.invoice
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: []) != nil)
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: [], allowingInitialMilestonePublication: true) == nil)
        invoice.customerSignedAt = Date()
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: [], allowingInitialMilestonePublication: true) != nil)
        invoice.customerSignedAt = nil; invoice.status = "paid"
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: [], allowingInitialMilestonePublication: true) != nil)
        invoice.status = "unpaid"; invoice.quickBooksID = "D1"
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: invoice, payments: [], allowingInitialMilestonePublication: true) != nil)
    }

    @Test func nativeLongNotesRemainPublishableWithMilestoneAndServerLineage() async throws {
        let f = try fixture()
        f.app.invoice.notes = String(repeating: "Finding ", count: 1000)
        let flow = try f.flow()
        _ = try await flow.execute()
        let request = try #require(f.request)
        #expect((request.document.PrivateNote?.count ?? 0) <= 3_800)
        #expect(try BillingMilestoneIdentity.reference(in: request.document.PrivateNote) == f.app.invoice.projectMilestoneID)
        #expect(f.writes == 1)
        f.finish(flow)
    }

    @Test func actualAllocatedBundleMilestonePublishesAndRecoversItsExactRepeatedComponents() async throws {
        let f = try fixture()
        let scope = QuickBooksChangeHistoryScope(companyID: f.company, realmID: "billing-realm", environment: Config.QuickBooks.environment)
        let catalog = try CatalogBundleFixture.makeCatalog(scope: scope)
        for item in catalog { f.app.context.insert(item) }
        let bundle = try CatalogBundlePolicy.resolve(root: catalog[3], catalog: catalog, scope: scope)
        let stages = try ProjectProgressAllocation.documents(from: CatalogLineItemSnapshot.encoded(snapshots: [bundle]),
            targetAmounts: [56.7, 94.5, 37.8])
        f.app.invoice.catalogSnapshotJSON = stages[0]; f.app.invoice.amount = 56.7
        let snapshot = f.app.invoice.catalogSnapshotJSON
        f.failReply = true
        let first = try f.flow()
        await #expect(throws: (any Error).self) { try await first.execute() }
        let group = try #require(f.request?.document.Line.first?.GroupLineDetail)
        #expect(group.Quantity == 0.3)
        #expect(group.Line.count == 2)
        #expect(group.Line.allSatisfy { $0.Amount == 28.35 && $0.SalesItemLineDetail.Qty == 0.3 && $0.SalesItemLineDetail.UnitPrice == 94.5 })
        #expect(f.writes == 1)
        f.finish(first); f.failReply = false
        f.journals.removeAll() // Same CloudKit model, independent device journal.
        let second = try f.flow()
        #expect(try await second.execute().recovered)
        #expect(f.app.invoice.catalogSnapshotJSON == snapshot)
        #expect(f.app.invoice.quickBooksID == "D1"); #expect(f.writes == 1)
        f.finish(second)
    }

    @Test func otherDeviceOriginalIsFoundBeforeCreatingAnInvoiceOrChangingTheLocalDraft() async throws {
        let f = try fixture(), other = UUID()
        f.milestoneOriginal = ["projectMilestoneID": f.app.invoice.projectMilestoneID!.uuidString,
            "localDocumentID": other.uuidString, "localCustomerID": f.app.customer.id.uuidString,
            "publicationID": UUID().uuidString, "state": "unknown"]
        let id = f.app.invoice.id, snapshot = f.app.invoice.catalogSnapshotJSON
        let flow = try f.flow()
        await #expect(throws: BillingNativeError.milestoneOriginal(other)) { try await flow.execute() }
        #expect(f.writes == 0); #expect(f.app.requests.isEmpty)
        #expect(f.calls.allSatisfy { $0.1 == "GET" }); #expect(f.journals.isEmpty)
        #expect(f.app.invoice.id == id); #expect(f.app.invoice.catalogSnapshotJSON == snapshot)
        #expect(f.app.invoice.quickBooksID == nil)
        f.finish(flow)
    }

    @Test func oldServerCannotSilentlyPublishAnUnprotectedMilestone() async throws {
        let f = try fixture(); f.milestoneVersion = nil
        let flow = try f.flow()
        await #expect(throws: BillingNativeError.milestoneServiceUnavailable) { try await flow.execute() }
        #expect(f.writes == 0); #expect(f.journals.isEmpty); #expect(f.app.requests.isEmpty)
        f.finish(flow)
    }

    @Test func wrongCustomerOrMilestoneResponseCannotBecomeAnOriginalHandoff() async throws {
        for wrongCustomer in [false, true] {
            let f = try fixture()
            f.milestoneOriginal = ["projectMilestoneID": (wrongCustomer ? f.app.invoice.projectMilestoneID! : UUID()).uuidString,
                "localDocumentID": UUID().uuidString, "localCustomerID": (wrongCustomer ? UUID() : f.app.customer.id).uuidString,
                "publicationID": UUID().uuidString, "state": "confirmed"]
            let flow = try f.flow()
            await #expect(throws: BillingPublicationError.invalidResponse) { try await flow.execute() }
            #expect(f.writes == 0); #expect(f.journals.isEmpty)
            f.finish(flow)
        }
    }

    @Test func localHandoffWaitsForOriginalAndRejectsAmbiguousOrWrongJobRecords() throws {
        let f = try fixture(), other = UUID()
        let identity = BillingMilestoneOriginal(projectMilestoneID: f.app.invoice.projectMilestoneID!,
            localDocumentID: other, localCustomerID: f.app.customer.id, publicationID: UUID(), state: .unknown)
        #expect(try identity.localInvoice(in: f.app.context, for: .invoice(f.app.invoice)) == nil)
        let original = Invoice(id: other, serviceCallID: f.app.invoice.serviceCallID, customer: f.app.customer,
            amount: 190, projectMilestoneID: f.app.invoice.projectMilestoneID)
        f.app.context.insert(original)
        #expect(try identity.localInvoice(in: f.app.context, for: .invoice(f.app.invoice)) === original)
        original.serviceCallID = UUID()
        #expect(throws: BillingPublicationError.invalidResponse) { try identity.localInvoice(in: f.app.context, for: .invoice(f.app.invoice)) }
        original.serviceCallID = f.app.invoice.serviceCallID
        f.app.context.insert(Invoice(id: other, customer: f.app.customer))
        #expect(throws: BillingPublicationError.invalidResponse) { try identity.localInvoice(in: f.app.context, for: .invoice(f.app.invoice)) }
    }
}
