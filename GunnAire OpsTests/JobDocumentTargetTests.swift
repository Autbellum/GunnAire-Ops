import Foundation
import SwiftData
import Testing
@testable import GunnAire_Ops

@MainActor struct JobDocumentTargetTests {
    func attachment(_ customer: Customer, job: UUID, invoice: UUID? = nil, estimate: UUID? = nil) -> ServiceDocumentAttachment {
        ServiceDocumentAttachment(customer: customer, serviceCallID: job, invoiceID: invoice, estimateID: estimate,
            kind: .serviceReport, displayName: "Findings.pdf", localFilePath: "/tmp/synthetic-findings.pdf",
            contentType: "application/pdf", fileSizeBytes: 12)
    }

    @Test func savedJobLinkWinsOverNewerBillingDocuments() {
        let customer = Customer(name: "Service customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let original = Invoice(serviceCallID: call.id, customer: customer, amount: 190,
            createdAt: Date(timeIntervalSince1970: 1))
        let newer = Invoice(serviceCallID: call.id, customer: customer, amount: 190)
        let estimate = Estimate(serviceCallID: call.id, customer: customer, amount: 190,
            createdAt: Date(timeIntervalSince1970: 1))
        let newerEstimate = Estimate(serviceCallID: call.id, customer: customer, amount: 190)
        call.linkedInvoiceID = original.id; call.linkedEstimateID = estimate.id
        let file = attachment(customer, job: call.id)
        let changed = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [newerEstimate, estimate], invoices: [newer, original], serviceCalls: [call], attachments: [file])
        #expect(changed == 2)
        #expect(file.invoiceID == original.id)
        #expect(file.estimateID == estimate.id)
    }

    @Test func unavailableStoredLinksNeverFallThroughToOtherDocuments() {
        let customer = Customer(name: "Service customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer,
            linkedEstimateID: UUID(), linkedInvoiceID: UUID())
        let file = attachment(customer, job: call.id)
        let changed = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [Estimate(serviceCallID: call.id, customer: customer)],
            invoices: [Invoice(serviceCallID: call.id, customer: customer)], serviceCalls: [call], attachments: [file])
        #expect(changed == 0)
        #expect(file.invoiceID == nil && file.estimateID == nil)
    }

    @Test func multipleLegacyDocumentsRequireSelectionNotNewestGuess() {
        let customer = Customer(name: "Service customer"), job = UUID()
        let file = attachment(customer, job: job)
        let changed = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [Estimate(serviceCallID: job, customer: customer), Estimate(serviceCallID: job, customer: customer)],
            invoices: [Invoice(serviceCallID: job, customer: customer), Invoice(serviceCallID: job, customer: customer)],
            attachments: [file])
        #expect(changed == 0)
        #expect(file.invoiceID == nil && file.estimateID == nil)
    }

    @Test func missingAttachmentCustomerDoesNotAuthorizeAutomaticOwnership() {
        let customer = Customer(name: "Still syncing"), job = UUID()
        let file = attachment(customer, job: job)
        file.customer = nil
        let changed = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [], invoices: [Invoice(serviceCallID: job, customer: customer)], attachments: [file])
        #expect(changed == 0 && file.invoiceID == nil && file.customer == nil)
    }

    @Test func duplicateInvoiceIDsCannotChooseAnUploadTarget() {
        let customer = Customer(name: "Service customer"), job = UUID(), id = UUID()
        let first = Invoice(id: id, serviceCallID: job, customer: customer, quickBooksID: "100")
        let conflicting = Invoice(id: id, serviceCallID: job, customer: customer, quickBooksID: "101")
        let file = attachment(customer, job: job, invoice: id)
        #expect(QuickBooksInvoiceAttachmentSync.pendingInvoiceAttachments(
            invoices: [first, conflicting], attachments: [file]).isEmpty)
        #expect(QuickBooksInvoiceAttachmentSync.quickBooksAttachableReferences(
            for: file, estimates: [], invoices: [first, conflicting]).isEmpty)
    }

    @Test func sameCustomerButDifferentJobCannotUploadAttachment() {
        let customer = Customer(name: "Repeated service")
        let invoice = Invoice(serviceCallID: UUID(), customer: customer, quickBooksID: "100")
        let estimate = Estimate(serviceCallID: UUID(), customer: customer, quickBooksID: "101")
        let file = attachment(customer, job: UUID(), invoice: invoice.id, estimate: estimate.id)
        #expect(!file.canUploadToQuickBooksInvoice(invoice))
        #expect(!file.canUploadToQuickBooksEstimate(estimate))
    }

    @Test func receiptDefaultsPreserveEstimateTypeAndInvoicePrecedence() {
        let customer = Customer(name: "Proposal customer")
        let call = ServiceCall(type: .estimate, scheduledDate: Date(), customer: customer)
        let estimate = Estimate(serviceCallID: call.id, customer: customer, quickBooksID: " 101 ")
        call.linkedEstimateID = estimate.id
        #expect(JobBillingDocumentLinks.attachmentTarget(for: call, invoices: [], estimates: [estimate], payments: []) ==
            .init(type: .estimate, id: "101"))
        call.linkedInvoiceID = UUID()
        #expect(JobBillingDocumentLinks.attachmentTarget(for: call, invoices: [], estimates: [estimate], payments: []) == nil)
    }

    @Test func retainedDraftResolvesNewFilesToOriginalWithoutMovingOwnedFiles() throws {
        let f = try BillingMilestoneReconciliationTests.Fixture()
        try f.retain()
        let call = ServiceCall(id: f.job, type: .service, scheduledDate: Date(), customer: f.app.customer,
            linkedInvoiceID: f.draft.id)
        let newFile = attachment(f.app.customer, job: f.job)
        let owned = attachment(f.app.customer, job: f.job, invoice: f.draft.id)
        let changed = QuickBooksInvoiceAttachmentSync.linkServiceCallAttachmentsToBillingDocuments(
            estimates: [], invoices: [f.draft, f.original], serviceCalls: [call], attachments: [newFile, owned])
        #expect(changed == 1 && newFile.invoiceID == f.original.id && owned.invoiceID == f.draft.id)
        #expect(call.linkedInvoiceID == f.draft.id)
        #expect(JobBillingDocumentLinks.attachmentTarget(for: call, invoices: [f.draft, f.original], estimates: [], payments: []) ==
            .init(type: .invoice, id: "D1"))
    }

    @Test func unresolvedAndForeignCustomersOrJobsCannotBecomeTargets() {
        let customer = Customer(name: "Customer"), other = Customer(name: "Other")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer)
        let invoice = Invoice(serviceCallID: UUID(), customer: customer, quickBooksID: "100")
        let estimate = Estimate(serviceCallID: call.id, customer: other, quickBooksID: "101")
        call.linkedInvoiceID = invoice.id; call.linkedEstimateID = estimate.id
        #expect(JobBillingDocumentLinks.invoice(for: call, in: [invoice], payments: []) == nil)
        #expect(JobBillingDocumentLinks.estimate(for: call, in: [estimate]) == nil)
        invoice.serviceCallID = call.id; invoice.customer = nil; estimate.customer = nil
        let file = attachment(customer, job: call.id, invoice: invoice.id, estimate: estimate.id)
        #expect(!file.canUploadToQuickBooksInvoice(invoice) && !file.canUploadToQuickBooksEstimate(estimate))
        #expect(JobBillingDocumentLinks.attachmentTarget(for: call, invoices: [invoice], estimates: [estimate], payments: []) == nil)
    }

    @Test func duplicateProviderAndFileIdentitiesAreNotUploadPermission() {
        let customer = Customer(name: "Customer"), job = UUID()
        let first = Invoice(serviceCallID: job, customer: customer, quickBooksID: "100")
        let duplicate = Invoice(serviceCallID: job, customer: customer, quickBooksID: "100")
        let file = attachment(customer, job: job, invoice: first.id)
        #expect(QuickBooksInvoiceAttachmentSync.pendingInvoiceAttachments(invoices: [first, duplicate], attachments: [file]).isEmpty)
        let fileReplica = attachment(customer, job: job, invoice: first.id)
        fileReplica.id = file.id
        #expect(QuickBooksInvoiceAttachmentSync.pendingQuickBooksAttachmentUploads(
            estimates: [], invoices: [first], attachments: [file, fileReplica]).isEmpty)
        #expect(QuickBooksInvoiceAttachmentSync.pendingQuickBooksAttachmentUploads(
            estimates: [], invoices: [first], attachments: [file, file]).count == 1)
    }

    @Test func operationalEstimateBackReferenceRemainsSupported() {
        let customer = Customer(name: "Customer")
        let call = ServiceCall(type: .install, scheduledDate: Date(), customer: customer)
        let estimate = Estimate(serviceCallID: UUID(), scheduledServiceCallID: call.id, customer: customer, quickBooksID: "101")
        let file = attachment(customer, job: call.id, estimate: estimate.id)
        #expect(JobBillingDocumentLinks.estimate(for: call, in: [estimate]) === estimate)
        #expect(file.canUploadToQuickBooksEstimate(estimate))
    }

    @Test func documentationStatusDoesNotInferPaymentFromMissingRecords() {
        let customer = Customer(name: "Customer")
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer, linkedInvoiceID: UUID())
        #expect(DocumentationQueueStatus.resolve(invoices: [], payments: [], visibleCalls: [call], includesAllInvoices: true) == .pendingSync)
        let invoice = Invoice(customer: customer)
        invoice.customer = nil
        #expect(DocumentationQueueStatus.resolve(invoices: [invoice], payments: [], visibleCalls: [], includesAllInvoices: true) == .pendingSync)
        #expect(DocumentationQueueStatus.resolve(invoices: [invoice], payments: [], visibleCalls: [], includesAllInvoices: false) == .empty)
        #expect(DocumentationQueueStatus.resolve(invoices: [], payments: [], visibleCalls: [], includesAllInvoices: true) == .empty)
        #expect(!DocumentationQueueStatus.current.message.contains("paid"))
    }

    @Test func documentationStatusKeepsInvalidLinksVisibleForReview() {
        let customer = Customer(name: "Customer")
        let invoice = Invoice(customer: Customer(name: "Different customer"))
        let call = ServiceCall(type: .service, scheduledDate: Date(), customer: customer, linkedInvoiceID: invoice.id)
        #expect(DocumentationQueueStatus.resolve(invoices: [invoice], payments: [], visibleCalls: [call], includesAllInvoices: true) == .review)
    }

    @Test func unverifiedZeroBalanceStillRequiresReviewAfterFinalization() {
        let invoice = Invoice(customer: Customer(name: "Customer"), quickBooksID: "100", quickBooksBalanceDue: 0,
            amount: 190, status: "paid", finalizedAt: Date())
        QuickBooksBalanceReconciliation.markForRefresh(invoice)
        #expect(DocumentationQueueStatus.resolve(invoices: [invoice], payments: [], visibleCalls: [], includesAllInvoices: true) == .review)
    }
}
