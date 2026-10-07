import Foundation
import SwiftData

@MainActor
enum QuickBooksInvoiceAttachmentSync {
    struct PendingLinkedUpload {
        let attachment: ServiceDocumentAttachment
        let references: [QuickBooksAttachableReference]
        let documents: [QuickBooksBillingDocument]
    }

    static func pendingLinkedUploadPage(context: ModelContext, offset: inout Int) throws -> [PendingLinkedUpload] {
        let descriptor = FetchDescriptor<ServiceDocumentAttachment>(predicate: #Predicate {
            $0.invoiceID != nil || $0.estimateID != nil || $0.serviceCallID != nil
        }, sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)])
        let page = try AutomaticOutboundSync.nextPage(descriptor, context: context, offset: &offset, pageSize: 25)
        let attachments = page.filter {
            $0.quickBooksAttachableID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
                FileManager.default.fileExists(atPath: $0.localFilePath)
        }
        try linkExplicitJobDocuments(attachments, context: context)
        var invoices: [Invoice] = []
        var estimates: [Estimate] = []
        var seenInvoices = Set<UUID>()
        var seenEstimates = Set<UUID>()
        for attachment in attachments {
            if let id = attachment.invoiceID, seenInvoices.insert(id).inserted {
                invoices += try context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id }))
            }
            if let id = attachment.estimateID, seenEstimates.insert(id).inserted {
                estimates += try context.fetch(FetchDescriptor<Estimate>(predicate: #Predicate { $0.id == id }))
            }
        }
        return pendingQuickBooksAttachmentUploads(estimates: estimates, invoices: invoices, attachments: attachments)
            .compactMap { attachment in
                let references = missingQuickBooksAttachableReferences(for: attachment, estimates: estimates, invoices: invoices)
                guard !references.isEmpty else { return nil }
                var documents: [QuickBooksBillingDocument] = []
                if references.contains(where: { $0.EntityRef.type == QuickBooksAttachableEntityType.invoice.rawValue }),
                   let id = attachment.invoiceID, let invoice = JobBillingDocumentLinks.invoice(id: id, in: invoices) {
                    documents.append(.invoice(invoice))
                }
                if references.contains(where: { $0.EntityRef.type == QuickBooksAttachableEntityType.estimate.rawValue }),
                   let id = attachment.estimateID, let estimate = JobBillingDocumentLinks.estimate(id: id, in: estimates) {
                    documents.append(.estimate(estimate))
                }
                guard documents.count == references.count else { return nil }
                return PendingLinkedUpload(attachment: attachment, references: references, documents: documents)
            }
    }

    private static func linkExplicitJobDocuments(_ attachments: [ServiceDocumentAttachment],
                                                 context: ModelContext) throws {
        var changed: [(ServiceDocumentAttachment, UUID?, UUID?, String?, String?, String?)] = []
        for attachment in attachments where attachment.canLinkToQuickBooksInvoiceAttachment &&
            (attachment.invoiceID == nil || attachment.estimateID == nil) {
            guard let jobID = attachment.serviceCallID,
                  let customer = attachment.customer else { continue }
            let calls = try context.fetch(FetchDescriptor<ServiceCall>(predicate: #Predicate { $0.id == jobID }))
            guard let call = JobBillingDocumentLinks.unique(calls), call.customer === customer else { continue }
            let oldInvoice = attachment.invoiceID, oldEstimate = attachment.estimateID
            let oldProvider = attachment.quickBooksAttachableID
            let oldKeys = attachment.quickBooksAttachedEntityKeysRaw
            let oldError = attachment.quickBooksSyncError
            if attachment.invoiceID == nil, attachment.canLinkToQuickBooksInvoiceDocument,
               let id = call.linkedInvoiceID {
                let matches = try context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id }))
                if let invoice = JobBillingDocumentLinks.unique(matches),
                   invoice.customer === customer,
                   invoice.quickBooksIdentityReviewMessage == nil,
                   invoice.serviceCallID == nil || invoice.serviceCallID == jobID,
                   attachment.canBePendingQuickBooksInvoiceAttachment(for: invoice),
                   attachment.quickBooksAttachableID == nil {
                    attachment.linkToInvoiceIfNeeded(invoice)
                }
            }
            if attachment.estimateID == nil, attachment.canLinkToQuickBooksEstimateDocument,
               let id = call.linkedEstimateID {
                let matches = try context.fetch(FetchDescriptor<Estimate>(predicate: #Predicate { $0.id == id }))
                if let estimate = JobBillingDocumentLinks.unique(matches),
                   estimate.customer === customer,
                   EstimateJobLineage.matches(jobID: jobID, diagnosticJobID: estimate.serviceCallID,
                                              scheduledJobID: estimate.scheduledServiceCallID),
                   QuickBooksBillingIdentity.identifier(estimate.quickBooksID) != nil,
                   attachment.quickBooksAttachableID == nil {
                    attachment.linkToEstimateIfNeeded(estimate)
                }
            }
            if oldInvoice != attachment.invoiceID || oldEstimate != attachment.estimateID {
                changed.append((attachment, oldInvoice, oldEstimate, oldProvider, oldKeys, oldError))
            }
        }
        guard !changed.isEmpty else { return }
        do { try context.save() }
        catch {
            for (attachment, invoiceID, estimateID, provider, keys, syncError) in changed {
                attachment.invoiceID = invoiceID
                attachment.estimateID = estimateID
                attachment.quickBooksAttachableID = provider
                attachment.quickBooksAttachedEntityKeysRaw = keys
                attachment.quickBooksSyncError = syncError
            }
            throw QBODocumentError.storage
        }
    }

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
