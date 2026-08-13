import Foundation
import SwiftData

@MainActor
enum QuickBooksInvoiceAttachmentSync {
    static func pendingServiceReports(
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

    static func syncPendingServiceReports(
        invoices: [Invoice],
        attachments: [ServiceDocumentAttachment],
        modelContext: ModelContext,
        api: QuickBooksDataAPI = .shared
    ) {
        guard api.isAuthenticated else { return }

        for pending in pendingServiceReports(invoices: invoices, attachments: attachments) {
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
    }
}
