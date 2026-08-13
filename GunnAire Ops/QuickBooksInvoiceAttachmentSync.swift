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

        for pending in pendingInvoiceAttachments(invoices: invoices, attachments: attachments) {
            let attachment = pending.attachment
            let invoice = pending.invoice
            guard let quickBooksID = invoice.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !quickBooksID.isEmpty else {
                continue
            }

            api.uploadDocument(
                fileURL: attachment.localFileURL,
                note: attachment.caption,
                attachToEntityType: .invoice,
                attachToEntityID: quickBooksID
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let attachableID):
                        attachment.quickBooksAttachableID = attachableID
                        attachment.quickBooksSyncError = nil
                    case .failure(let error):
                        attachment.quickBooksSyncError = error.localizedDescription
                    }
                    try? modelContext.save()
                }
            }
        }

        for pending in pendingEstimateAttachments(estimates: estimates, attachments: attachments) {
            let attachment = pending.attachment
            let estimate = pending.estimate
            guard let quickBooksID = estimate.quickBooksID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !quickBooksID.isEmpty else {
                continue
            }

            api.uploadDocument(
                fileURL: attachment.localFileURL,
                note: attachment.caption,
                attachToEntityType: .estimate,
                attachToEntityID: quickBooksID
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let attachableID):
                        attachment.quickBooksAttachableID = attachableID
                        attachment.quickBooksSyncError = nil
                    case .failure(let error):
                        attachment.quickBooksSyncError = error.localizedDescription
                    }
                    try? modelContext.save()
                }
            }
        }
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

            if attachment.invoiceID == nil,
               let invoice = invoicesByServiceCallID[serviceCallID],
               attachment.customerMatches(invoice.customer) {
                attachment.linkToInvoiceIfNeeded(invoice)
                changed += 1
            }

            if attachment.estimateID == nil,
               let estimate = estimatesByServiceCallID[serviceCallID],
               attachment.customerMatches(estimate.customer) {
                attachment.linkToEstimateIfNeeded(estimate)
                changed += 1
            }
        }
        return changed
    }
}
