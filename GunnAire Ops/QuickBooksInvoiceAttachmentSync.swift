import Foundation
import SwiftData

@MainActor
enum QuickBooksInvoiceAttachmentSync {
    static func pendingInvoiceAttachments(
        invoices: [Invoice],
        attachments: [ServiceDocumentAttachment]
    ) -> [(attachment: ServiceDocumentAttachment, invoice: Invoice)] {
        attachments.compactMap { attachment in
            guard let invoice = invoices.first(where: { attachment.canUploadToQuickBooksInvoice($0) }) else {
                return nil
            }
            return (attachment, invoice)
        }
    }

    static func pendingEstimateAttachments(
        estimates: [Estimate],
        attachments: [ServiceDocumentAttachment]
    ) -> [(attachment: ServiceDocumentAttachment, estimate: Estimate)] {
        attachments.compactMap { attachment in
            guard let estimate = estimates.first(where: { attachment.canUploadToQuickBooksEstimate($0) }) else {
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
        attachments: [ServiceDocumentAttachment],
        modelContext: ModelContext
    ) {
        syncPendingServiceReports(
            estimates: estimates,
            invoices: invoices,
            attachments: attachments,
            modelContext: modelContext,
            api: QuickBooksDataAPI.shared
        )
    }

    static func syncPendingServiceReports(
        estimates: [Estimate] = [],
        invoices: [Invoice],
        attachments: [ServiceDocumentAttachment],
        modelContext: ModelContext,
        api: QuickBooksDataAPI
    ) {
        guard api.isAuthenticated else { return }

        if linkServiceCallAttachmentsToBillingDocuments(
            estimates: estimates,
            invoices: invoices,
            attachments: attachments
        ) > 0 {
            try? modelContext.save()
        }

        for attachment in pendingQuickBooksAttachmentUploads(estimates: estimates, invoices: invoices, attachments: attachments) {
            let references = missingQuickBooksAttachableReferences(for: attachment, estimates: estimates, invoices: invoices)
            guard !references.isEmpty else {
                continue
            }

            api.uploadDocument(
                fileURL: attachment.localFileURL,
                note: attachment.caption,
                attachableReferences: references
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let attachableID):
                        attachment.quickBooksAttachableID = attachableID
                        attachment.markQuickBooksAttached(to: references)
                        attachment.quickBooksSyncError = nil
                    case .failure(let error):
                        attachment.quickBooksSyncError = error.localizedDescription
                    }
                    try? modelContext.save()
                }
            }
        }
    }

    static func pendingQuickBooksAttachmentUploads(
        estimates: [Estimate],
        invoices: [Invoice],
        attachments: [ServiceDocumentAttachment]
    ) -> [ServiceDocumentAttachment] {
        var seenAttachmentIDs: Set<UUID> = []
        return attachments.filter { attachment in
            guard !missingQuickBooksAttachableReferences(for: attachment, estimates: estimates, invoices: invoices).isEmpty,
                  seenAttachmentIDs.insert(attachment.id).inserted else {
                return false
            }
            return true
        }
    }

    static func quickBooksAttachableReferences(
        for attachment: ServiceDocumentAttachment,
        estimates: [Estimate],
        invoices: [Invoice]
    ) -> [QuickBooksAttachableReference] {
        var references: [QuickBooksAttachableReference] = []
        if let invoice = invoices.first(where: { attachment.canUploadToQuickBooksInvoice($0) }),
           let reference = attachment.quickBooksInvoiceReference(for: invoice) {
            references.append(reference)
        }
        if let estimate = estimates.first(where: { attachment.canUploadToQuickBooksEstimate($0) }),
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
        attachments: [ServiceDocumentAttachment]
    ) -> Int {
        let invoicesByServiceCallID = Dictionary(
            invoices.compactMap { invoice -> (UUID, Invoice)? in
                guard let serviceCallID = invoice.serviceCallID else { return nil }
                return (serviceCallID, invoice)
            },
            uniquingKeysWith: { existing, candidate in
                existing.createdAt >= candidate.createdAt ? existing : candidate
            }
        )
        let estimatesByServiceCallID = Dictionary(
            estimates.compactMap { estimate -> (UUID, Estimate)? in
                guard let serviceCallID = estimate.serviceCallID else { return nil }
                return (serviceCallID, estimate)
            },
            uniquingKeysWith: { existing, candidate in
                existing.createdAt >= candidate.createdAt ? existing : candidate
            }
        )

        var changed = 0
        for attachment in attachments where attachment.canLinkToQuickBooksInvoiceAttachment {
            guard let serviceCallID = attachment.serviceCallID else { continue }

            if attachment.canLinkToQuickBooksInvoiceDocument,
               attachment.invoiceID == nil,
               let invoice = invoicesByServiceCallID[serviceCallID],
               attachment.customerMatches(invoice.customer) {
                attachment.linkToInvoiceIfNeeded(invoice)
                changed += 1
            }

            if attachment.canLinkToQuickBooksEstimateDocument,
               attachment.estimateID == nil,
               let estimate = estimatesByServiceCallID[serviceCallID],
               attachment.customerMatches(estimate.customer) {
                attachment.linkToEstimateIfNeeded(estimate)
                changed += 1
            }
        }
        return changed
    }
}
