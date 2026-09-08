import Foundation
import SwiftData
import CoreData
import Testing
@testable import GunnAire_Ops

@MainActor struct BillingMilestoneReconciliationTests {
    @MainActor final class Fixture {
        let app: QuickBooksBillingWorkflowTests.Fixture
        let original: Invoice
        let reviewer = AppUser(email: "accounting@example.invalid", role: .accounting)
        let company = UUID(), stage = UUID(), job = UUID(), attempt = UUID()
        var draft: Invoice { app.invoice }
        var context: ModelContext { app.context }
        var scope: BillingDocumentScope { .init(companyID: company, realmID: "R1", environment: "sandbox",
            documentType: .invoice, localDocumentID: draft.id) }
        var evidence: BillingMilestoneOriginal { .init(projectMilestoneID: stage, localDocumentID: original.id,
            localCustomerID: app.customer.id, publicationID: attempt, state: .confirmed) }
        var proposal: BillingOriginalProposal {
            .init(publication: .init(id: attempt, companyID: company, realmID: "R1", environment: "sandbox",
                documentType: .invoice, localDocumentID: original.id, localCustomerID: app.customer.id,
                operation: .create, state: .confirmed, providerID: "D1", updatedAt: "2026-09-08T12:00:00Z"),
                proposal: .init(companyID: company, realmID: "R1", environment: "sandbox", documentType: .invoice,
                    localDocumentID: original.id, localCustomerID: app.customer.id, operation: .create,
                    document: .init(CustomerRef: .init(value: "C1", name: nil), Line: [
                        .init(Amount: 190, DetailType: "SalesItemLineDetail", Description: "Diagnostic",
                            SalesItemLineDetail: .init(ItemRef: .init(value: "I1", name: nil), Qty: 1, UnitPrice: 190,
                                TaxCodeRef: .init(value: "NON", name: nil)))
                    ], TxnDate: "2026-09-08"),
                    connectionRevision: String(repeating: "a", count: 64), serviceCallID: job, projectMilestoneID: stage))
        }
        init() throws {
            app = try .init()
            original = Invoice(serviceCallID: job, customer: app.customer, quickBooksID: "D1",
                quickBooksBalanceDue: 190, catalogSnapshotJSON: app.invoice.catalogSnapshotJSON, amount: 190,
                projectMilestoneID: stage, projectMilestoneTitle: "Deposit")
            draft.serviceCallID = job; draft.projectMilestoneID = stage
            draft.notes = "Different visit notes must survive"
            context.insert(original); context.insert(reviewer)
            try context.save()
        }
        func retain(persist: (() throws -> Void)? = nil, check: () throws -> Void = {}) throws {
            try BillingMilestoneReconciliation.save(draft: draft, original: original, evidence: evidence,
                publication: proposal, scope: scope, reviewer: reviewer, context: context, check: check,
                persist: persist ?? { try self.context.save() })
        }
        func projection() throws -> BillingMilestoneReconciliation.Projection {
            BillingMilestoneReconciliation.project(try context.fetch(FetchDescriptor<Invoice>()),
                payments: try context.fetch(FetchDescriptor<Payment>()))
        }
    }

    @Test func unresolvedMilestoneDuplicatesAreNotVerifiedFinancialTotals() throws {
        let f = try Fixture()
        #expect(try f.projection().needsReview)
        #expect(!f.draft.isReadyForPaymentCollection && !f.original.isReadyForPaymentCollection)
        let report = BusinessReporting.snapshot(period: .currentMonth, serviceCalls: [], estimates: [],
            invoices: [f.draft, f.original], payments: [], timeEntries: [], technicians: [])
        #expect(report.billingIdentityReviewMessage != nil)
        let statement = CustomerAccountStatementPolicy.snapshot(customer: f.app.customer,
            invoices: [f.draft, f.original], payments: [], asOf: nil, calendar: .current, now: Date())
        #expect(!statement.reviewMessages.isEmpty)
        let account = CustomerIntelligence.snapshot(for: f.app.customer, serviceCalls: [], invoices: [f.draft, f.original],
            estimates: [], payments: [], contracts: [])
        #expect(account.billingReviewMessage != nil && account.primaryAction == .reviewInvoices)
    }

    @Test func reviewedDraftStaysStoredWhileOriginalAloneContributesToReportsAndStatements() throws {
        let f = try Fixture()
        let attachment = ServiceDocumentAttachment(customer: f.app.customer, serviceCallID: f.job,
            invoiceID: f.draft.id, kind: .serviceReport, displayName: "Retained findings.pdf", localFilePath: "/tmp/not-a-real-file.pdf",
            contentType: "application/pdf", fileSizeBytes: 12)
        f.context.insert(attachment); try f.context.save()
        let id = f.draft.id, notes = f.draft.notes, snapshot = f.draft.catalogSnapshotJSON
        try f.retain()
        let projection = try f.projection()
        #expect(!projection.needsReview && projection.activeInvoices.count == 1 && projection.retainedDrafts.count == 1)
        #expect(projection.activeInvoices.first === f.original)
        #expect(f.original.isReadyForPaymentCollection)
        #expect(try f.context.fetch(FetchDescriptor<Invoice>()).count == 2)
        #expect(f.draft.id == id && f.draft.notes == notes && f.draft.catalogSnapshotJSON == snapshot)
        #expect(attachment.invoiceID == id && attachment.customer === f.app.customer)
        #expect(!f.draft.isReadyForPaymentCollection)
        #expect(BillingInvoiceMutationPolicy.blockedMessage(for: f.draft, payments: [], allowingInitialMilestonePublication: true) != nil)
        let report = BusinessReporting.snapshot(period: .currentMonth, serviceCalls: [], estimates: [],
            invoices: [f.draft, f.original], payments: [], timeEntries: [], technicians: [])
        #expect(report.billingIdentityReviewMessage == nil && report.invoicedRevenue == 190 && report.invoiceCount == 1)
        let statement = CustomerAccountStatementPolicy.snapshot(customer: f.app.customer,
            invoices: [f.draft, f.original], payments: [], asOf: nil, calendar: .current, now: Date())
        #expect(statement.reviewMessages.isEmpty && statement.totalBalance == 190)
        let account = CustomerIntelligence.snapshot(for: f.app.customer, serviceCalls: [], invoices: [f.draft, f.original],
            estimates: [], payments: [], contracts: [])
        #expect(account.billingReviewMessage == nil && account.openBalance == 190 && account.openInvoiceCount == 1)
        #expect(Invoice.outstandingBalance(for: f.draft, payments: []) == 0 && !Invoice.isPaid(f.draft, payments: []))
        let fresh = ModelContext(f.context.container)
        let restored = try #require(fresh.fetch(FetchDescriptor<Invoice>()).first { $0.id == id })
        #expect(BillingMilestoneReconciliation.receipt(restored)?.originalInvoiceID == f.original.id)
    }

    @Test func changedRetainedSnapshotOrNewPaymentRequiresReviewWithoutHidingIt() throws {
        let f = try Fixture(); try f.retain()
        f.draft.notes = "Changed after review"
        #expect(try f.projection().needsReview)
        #expect(try f.projection().retainedDrafts.isEmpty)
        f.draft.notes = "Different visit notes must survive"
        let payment = Payment(invoice: f.draft, amount: 1, method: "cash")
        f.context.insert(payment)
        #expect(try f.projection().needsReview)
        #expect(try f.projection().activeInvoices.count == 2)
        #expect(payment.invoice === f.draft)
    }

    @Test func missingOriginalOrWrongProviderCannotMakeDuplicateLookResolved() throws {
        let f = try Fixture(); try f.retain()
        #expect(BillingMilestoneReconciliation.project([f.draft], payments: []).needsReview)
        f.original.quickBooksID = "OTHER"
        #expect(try f.projection().needsReview)
        f.original.quickBooksID = "D1"; f.original.serviceCallID = UUID()
        #expect(try f.projection().needsReview)
    }

    @Test func originalOutsideReportPeriodDoesNotMoveRevenueToDuplicateDate() throws {
        let f = try Fixture(); try f.retain()
        f.original.createdAt = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
        let report = BusinessReporting.snapshot(period: .currentMonth, serviceCalls: [], estimates: [],
            invoices: [f.draft, f.original], payments: [], timeEntries: [], technicians: [])
        #expect(report.billingIdentityReviewMessage == nil && report.invoiceCount == 0 && report.invoicedRevenue == 0)
    }

    @Test func unauthorizedSignedPaidAndAlreadyLinkedDraftsCannotBeRetained() throws {
        for mode in 0..<5 {
            let f = try Fixture()
            if mode == 0 { f.reviewer.role = .fieldTechnician }
            if mode == 1 { f.draft.customerSignedAt = Date() }
            if mode == 2 { f.context.insert(Payment(invoice: f.draft, amount: 10, method: "cash")) }
            if mode == 3 { f.draft.quickBooksID = "OTHER" }
            if mode == 4 { f.draft.quickBooksSyncStatus = "unknown" }
            #expect(throws: (any Error).self) { try f.retain() }
            #expect(f.draft.milestoneDraftReceiptJSON == nil)
        }
    }

    @Test func receiptSaveFailureRestoresOnlyOurFieldAndPreservesUnrelatedEdits() throws {
        let f = try Fixture()
        f.app.customer.phone = "Fixture updated phone"
        struct SaveFailure: Error {}
        #expect(throws: SaveFailure.self) { try f.retain(persist: { throw SaveFailure() }) }
        #expect(f.draft.milestoneDraftReceiptJSON == nil)
        #expect(f.app.customer.phone == "Fixture updated phone")
        let fresh = ModelContext(f.context.container)
        #expect(try fresh.fetch(FetchDescriptor<Invoice>()).allSatisfy { $0.milestoneDraftReceiptJSON == nil })
    }

    @Test func duplicateModelIdentityAndConflictingCustomerCannotBeSelectedArbitrarily() throws {
        let f = try Fixture()
        let duplicate = Invoice(id: f.original.id, customer: f.app.customer)
        f.context.insert(duplicate)
        #expect(throws: (any Error).self) { try f.retain() }
        #expect(f.draft.milestoneDraftReceiptJSON == nil)
    }

    @Test func independentStagesAndOrdinaryEqualInvoicesRemainIndependent() throws {
        let f = try Fixture()
        f.draft.projectMilestoneID = UUID()
        #expect(try !f.projection().needsReview)
        #expect(try f.projection().activeInvoices.count == 2)
        f.draft.projectMilestoneID = nil; f.original.projectMilestoneID = nil
        #expect(try !f.projection().needsReview)
        #expect(try f.projection().activeInvoices.count == 2)
    }

    @Test func oldProjectLinkResolvesToOriginalWithoutRewritingItsHistory() throws {
        let f = try Fixture(); try f.retain()
        let milestone = ProjectMilestone(projectServiceCallID: f.job, estimateID: UUID(), sequence: 0,
            title: "Deposit", plannedDate: Date(), billingPercent: 30, plannedAmount: 190,
            billingTrigger: .customerApproval, invoiceID: f.draft.id)
        #expect(milestone.linkedInvoice(in: [f.draft, f.original]) === f.original)
        #expect(milestone.invoiceID == f.draft.id)
    }

    @Test func preReceiptSQLiteInvoiceMigratesWithoutRekeyingOrLosingItsCustomer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MilestoneMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Milestone.store")
        let invoiceID = UUID(), customerID = UUID(), stageID = UUID(), jobID = UUID()
        // Use the actual generated model, removing only the newly added optional
        // field before creating the old SQLite store. This is a real migration,
        // not a current-schema row initialized with nil.
        try autoreleasepool {
            let generated = try #require(NSManagedObjectModel.makeManagedObjectModel(for: [Invoice.self, Customer.self, Payment.self]))
            let model = try #require(generated.copy() as? NSManagedObjectModel)
            let entity = try #require(model.entitiesByName["Invoice"])
            #expect(entity.attributesByName["milestoneDraftReceiptJSON"] != nil)
            entity.properties.removeAll { $0.name == "milestoneDraftReceiptJSON" }
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let customer = NSEntityDescription.insertNewObject(forEntityName: "Customer", into: context)
            customer.setValue(customerID, forKey: "id"); customer.setValue("Legacy customer", forKey: "name")
            let invoice = NSEntityDescription.insertNewObject(forEntityName: "Invoice", into: context)
            invoice.setValue(invoiceID, forKey: "id"); invoice.setValue(customer, forKey: "customer")
            invoice.setValue(stageID, forKey: "projectMilestoneID"); invoice.setValue(jobID, forKey: "serviceCallID")
            invoice.setValue(190, forKey: "amount"); invoice.setValue("Retained legacy findings", forKey: "notes")
            try context.save()
            context.reset(); try coordinator.remove(store)
        }
        let schema = GunnAireModelSchema.schema
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration("MilestoneMigration", schema: schema, url: url, cloudKitDatabase: .none)])
        let migrated = try #require(container.mainContext.fetch(FetchDescriptor<Invoice>()).first)
        #expect(migrated.id == invoiceID && migrated.customer?.id == customerID)
        #expect(migrated.projectMilestoneID == stageID && migrated.serviceCallID == jobID)
        #expect(migrated.amount == 190 && migrated.notes == "Retained legacy findings")
        #expect(migrated.milestoneDraftReceiptJSON == nil)
    }

    @Test func jobBillingAndCollectionFollowReviewedOriginalWithoutRewritingHistory() throws {
        let f = try Fixture(); try f.retain()
        let call = ServiceCall(id: f.job, type: .repair, scheduledDate: Date(),
            customer: f.app.customer, linkedInvoiceID: f.draft.id)
        let original = BillingMilestoneReconciliation.linkedInvoice(for: call,
            in: [f.draft, f.original], payments: [])
        #expect(original === f.original)
        #expect(original?.id != call.linkedInvoiceID)
        #expect(call.linkedInvoiceID == f.draft.id)
        #expect(original?.isReadyForPaymentCollection == true)
        #expect(Invoice.outstandingBalance(for: f.original, payments: []) == 190)
    }

    @Test func jobWithMissingOrChangedOriginalRetainsBlockedDraftInsteadOfOfferingAnotherInvoice() throws {
        let f = try Fixture(); try f.retain()
        let call = ServiceCall(id: f.job, type: .repair, scheduledDate: Date(),
            customer: f.app.customer, linkedInvoiceID: f.draft.id)
        #expect(BillingMilestoneReconciliation.linkedInvoice(for: call, in: [f.draft], payments: []) === f.draft)
        f.original.quickBooksID = "changed-original"
        let unresolved = BillingMilestoneReconciliation.linkedInvoice(for: call, in: [f.draft, f.original], payments: [])
        #expect(unresolved === f.draft && unresolved?.isReadyForPaymentCollection == false)
        #expect(call.linkedInvoiceID == f.draft.id)
    }

    @Test func jobInvoiceLookupRejectsForeignCustomerJobAndAmbiguousIdentity() throws {
        let f = try Fixture()
        let call = ServiceCall(id: f.job, type: .repair, scheduledDate: Date(),
            customer: f.app.customer, linkedInvoiceID: f.draft.id)
        #expect(BillingMilestoneReconciliation.linkedInvoice(for: call, in: [f.draft], payments: []) === f.draft)
        call.customer = Customer(name: "Another customer")
        #expect(BillingMilestoneReconciliation.linkedInvoice(for: call, in: [f.draft], payments: []) == nil)
        call.customer = f.app.customer; f.draft.serviceCallID = UUID()
        #expect(BillingMilestoneReconciliation.linkedInvoice(for: call, in: [f.draft], payments: []) == nil)
        f.draft.serviceCallID = f.job
        let duplicate = Invoice(id: f.draft.id, customer: f.app.customer)
        #expect(BillingMilestoneReconciliation.linkedInvoice(for: call, in: [f.draft, duplicate], payments: []) == nil)
    }

    @Test func foreignBusinessOrRevokedReviewCannotPersistAndMalformedReceiptRemainsVisible() throws {
        let f = try Fixture()
        let foreign = BillingDocumentScope(companyID: UUID(), realmID: "R1", environment: "sandbox",
            documentType: .invoice, localDocumentID: f.draft.id)
        #expect(throws: (any Error).self) {
            try BillingMilestoneReconciliation.save(draft: f.draft, original: f.original, evidence: f.evidence,
                publication: f.proposal, scope: foreign, reviewer: f.reviewer, context: f.context,
                check: {}, persist: { try f.context.save() })
        }
        #expect(f.draft.milestoneDraftReceiptJSON == nil)
        #expect(throws: QuickBooksBillingWorkflowError.changed) {
            try f.retain(check: { throw QuickBooksBillingWorkflowError.changed })
        }
        f.draft.milestoneDraftReceiptJSON = "not a valid review receipt"
        #expect(try f.projection().needsReview)
        #expect(try f.projection().retainedDrafts.isEmpty)
        #expect(!f.draft.isReadyForPaymentCollection)
    }
}
