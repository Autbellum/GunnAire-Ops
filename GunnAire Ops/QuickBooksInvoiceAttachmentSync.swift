import Foundation
import SwiftData

@MainActor
enum QuickBooksInvoiceAttachmentSync {
    static func pendingInvoiceAttachments(
        invoices: [Invoice],
        attachments: [ServiceDocumentAttachment]
    ) -> [(attachment: ServiceDocumentAttachment, invoice: Invoice)] {
        uniqueAttachments(attachments).compactMap { attachment in
            guard let id = attachment.invoiceID,
                  let invoice = JobBillingDocumentLinks.invoice(id: id, in: invoices),
                  attachment.canUploadToQuickBooksInvoice(invoice) else {
                return nil
            }
            return (attachment, invoice)
        }
    }

    static func pendingEstimateAttachments(
        estimates: [Estimate],
        attachments: [ServiceDocumentAttachment]
    ) -> [(attachment: ServiceDocumentAttachment, estimate: Estimate)] {
        uniqueAttachments(attachments).compactMap { attachment in
            guard let id = attachment.estimateID,
                  let estimate = JobBillingDocumentLinks.estimate(id: id, in: estimates),
                  attachment.canUploadToQuickBooksEstimate(estimate) else {
                return nil
            }
            return (attachment, estimate)
        }
    }

    static func pendingServiceReports(
        invoices: [Invoice],
        attachments: [ServiceDocumentAttachment]
    ) -> [(attachment: ServiceDocumentAttachment, invoice: Invoice)] {
        pendingInvoiceAttachments(invoices: invoices, attachments: attachments)
    }

    static func syncPendingServiceReports(
        estimates: [Estimate] = [],
        invoices: [Invoice],
        serviceCalls: [ServiceCall] = [],
        payments: [Payment] = [],
        attachments: [ServiceDocumentAttachment],
        modelContext: ModelContext
    ) throws {
        try syncPendingServiceReports(
            estimates: estimates,
            invoices: invoices,
            serviceCalls: serviceCalls,
            payments: payments,
            attachments: attachments,
            modelContext: modelContext,
            api: QuickBooksDataAPI.shared
        )
    }

    static func syncPendingServiceReports(
        estimates: [Estimate] = [],
        invoices: [Invoice],
        serviceCalls: [ServiceCall] = [],
        payments: [Payment] = [],
        attachments: [ServiceDocumentAttachment],
        modelContext: ModelContext,
        api: QuickBooksDataAPI,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        guard api.isAuthenticated else { return }

        let originalLinks = attachments.map { attachment in
            (attachment, attachment.invoiceID, attachment.estimateID, attachment.quickBooksAttachableID,
             attachment.quickBooksAttachedEntityKeysRaw, attachment.quickBooksSyncError)
        }

        if linkServiceCallAttachmentsToBillingDocuments(
            estimates: estimates,
            invoices: invoices,
            serviceCalls: serviceCalls,
            payments: payments,
            attachments: attachments
        ) > 0 {
            do { try save(modelContext) }
            catch {
                for (attachment, invoice, estimate, provider, keys, error) in originalLinks {
                    attachment.invoiceID = invoice; attachment.estimateID = estimate
                    attachment.quickBooksAttachableID = provider; attachment.quickBooksAttachedEntityKeysRaw = keys
                    attachment.quickBooksSyncError = error
                }
                throw QBODocumentError.storage
            }
        }

        for attachment in pendingQuickBooksAttachmentUploads(estimates: estimates, invoices: invoices, attachments: attachments) {
            let references = missingQuickBooksAttachableReferences(for: attachment, estimates: estimates, invoices: invoices)
            guard !references.isEmpty else {
                continue
            }

            QBODocumentNativeWorkflow.enqueue(attachment, references: references, context: modelContext, api: api)
        }
    }

    static func pendingQuickBooksAttachmentUploads(
        estimates: [Estimate],
        invoices: [Invoice],
        attachments: [ServiceDocumentAttachment]
    ) -> [ServiceDocumentAttachment] {
        uniqueAttachments(attachments).filter { attachment in
            !missingQuickBooksAttachableReferences(for: attachment, estimates: estimates, invoices: invoices).isEmpty
        }
    }

    private static func uniqueAttachments(_ attachments: [ServiceDocumentAttachment]) -> [ServiceDocumentAttachment] {
        let groups = Dictionary(grouping: attachments, by: \.id)
        var seen = Set<UUID>()
        return attachments.filter {
            JobBillingDocumentLinks.unique(groups[$0.id] ?? []) != nil && seen.insert($0.id).inserted
        }
    }

    static func quickBooksAttachableReferences(
        for attachment: ServiceDocumentAttachment,
        estimates: [Estimate],
        invoices: [Invoice]
    ) -> [QuickBooksAttachableReference] {
        var references: [QuickBooksAttachableReference] = []
        if let id = attachment.invoiceID,
           let invoice = JobBillingDocumentLinks.invoice(id: id, in: invoices),
           attachment.canUploadToQuickBooksInvoice(invoice),
           let reference = attachment.quickBooksInvoiceReference(for: invoice) {
            references.append(reference)
        }
        if let id = attachment.estimateID,
           let estimate = JobBillingDocumentLinks.estimate(id: id, in: estimates),
           attachment.canUploadToQuickBooksEstimate(estimate),
           let reference = attachment.quickBooksEstimateReference(for: estimate) {
            references.append(reference)
        }
        return references
    }

    static func missingQuickBooksAttachableReferences(
        for attachment: ServiceDocumentAttachment,
        estimates: [Estimate],
        invoices: [Invoice]
    ) -> [QuickBooksAttachableReference] {
        quickBooksAttachableReferences(for: attachment, estimates: estimates, invoices: invoices)
            .filter { !attachment.isQuickBooksAttached(to: [$0]) }
    }

    @discardableResult
    static func linkServiceCallAttachmentsToBillingDocuments(
        estimates: [Estimate],
        invoices: [Invoice],
        serviceCalls: [ServiceCall] = [],
        payments: [Payment] = [],
        attachments: [ServiceDocumentAttachment]
    ) -> Int {
        let activeInvoices = BillingMilestoneReconciliation.project(invoices, payments: payments).activeInvoices
        var changed = 0
        for attachment in uniqueAttachments(attachments) where attachment.canLinkToQuickBooksInvoiceAttachment {
            guard let serviceCallID = attachment.serviceCallID, let customer = attachment.customer else { continue }
            let calls = serviceCalls.filter { $0.id == serviceCallID }
            let invoice: Invoice?
            let estimate: Estimate?
            if !calls.isEmpty {
                guard let call = JobBillingDocumentLinks.unique(calls), call.customer === customer else { continue }
                invoice = JobBillingDocumentLinks.invoice(for: call, in: invoices, payments: payments)
                estimate = JobBillingDocumentLinks.estimate(for: call, in: estimates)
            } else {
                // Legacy files can precede the operational record. Only an exact,
                // unique back-reference can fill an absent link; never pick a date.
                invoice = JobBillingDocumentLinks.unique(activeInvoices.filter { $0.serviceCallID == serviceCallID && $0.customer === customer })
                estimate = JobBillingDocumentLinks.unique(estimates.filter {
                    ($0.serviceCallID == serviceCallID || $0.scheduledServiceCallID == serviceCallID) && $0.customer === customer
                })
            }

            if attachment.canLinkToQuickBooksInvoiceDocument,
               attachment.invoiceID == nil,
               let invoice, invoice.quickBooksIdentityReviewMessage == nil,
               JobBillingDocumentLinks.invoice(id: invoice.id, in: invoices) === invoice {
                attachment.linkToInvoiceIfNeeded(invoice)
                changed += 1
            }

            if attachment.canLinkToQuickBooksEstimateDocument,
               attachment.estimateID == nil,
               let estimate,
               JobBillingDocumentLinks.estimate(id: estimate.id, in: estimates) === estimate {
                attachment.linkToEstimateIfNeeded(estimate)
                changed += 1
            }
        }
        return changed
    }
}
