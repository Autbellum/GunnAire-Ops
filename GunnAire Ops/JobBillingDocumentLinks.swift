import Foundation

/// A proposal may start without a visit, then retain both its diagnostic visit
/// and scheduled work order. A missing diagnostic visit is not a wildcard once
/// a work order is recorded. This checks lineage only, never customer access.
nonisolated enum EstimateJobLineage {
    static func matches(jobID: UUID?, diagnosticJobID: UUID?, scheduledJobID: UUID?) -> Bool {
        guard let jobID else { return true }
        return (diagnosticJobID == nil && scheduledJobID == nil)
            || diagnosticJobID == jobID || scheduledJobID == jobID
    }
}

/// Resolve saved document identities, never creation order, display names or amounts.
/// This only selects an existing record; it never rewrites historical file ownership.
@MainActor enum JobBillingDocumentLinks {
    static func unique<T: AnyObject>(_ records: [T]) -> T? {
        Set(records.map(ObjectIdentifier.init)).count == 1 ? records.first : nil
    }

    static func invoice(id: UUID, in invoices: [Invoice]) -> Invoice? {
        guard let invoice = unique(invoices.filter { $0.id == id }) else { return nil }
        if let providerID = QuickBooksBillingIdentity.identifier(invoice.quickBooksID),
           unique(invoices.filter { QuickBooksBillingIdentity.identifier($0.quickBooksID) == providerID }) == nil {
            return nil
        }
        return invoice
    }

    static func estimate(id: UUID, in estimates: [Estimate]) -> Estimate? {
        guard let estimate = unique(estimates.filter { $0.id == id }) else { return nil }
        if let providerID = QuickBooksBillingIdentity.identifier(estimate.quickBooksID),
           unique(estimates.filter { QuickBooksBillingIdentity.identifier($0.quickBooksID) == providerID }) == nil {
            return nil
        }
        return estimate
    }

    static func invoice(for call: ServiceCall, in invoices: [Invoice], payments: [Payment]) -> Invoice? {
        guard let resolved = BillingMilestoneReconciliation.documentationInvoice(for: call, in: invoices, payments: payments),
              invoice(id: resolved.id, in: invoices) === resolved,
              resolved.quickBooksIdentityReviewMessage == nil else { return nil }
        return resolved
    }

    static func estimate(for call: ServiceCall, in estimates: [Estimate]) -> Estimate? {
        guard let customer = call.customer else { return nil }
        let matches: [Estimate]
        if let id = call.linkedEstimateID {
            matches = estimates.filter { $0.id == id }
        } else {
            matches = estimates.filter { $0.serviceCallID == call.id || $0.scheduledServiceCallID == call.id }
        }
        guard let resolved = unique(matches), resolved.customer === customer,
              EstimateJobLineage.matches(jobID: call.id, diagnosticJobID: resolved.serviceCallID,
                                        scheduledJobID: resolved.scheduledServiceCallID),
              estimate(id: resolved.id, in: estimates) === resolved else { return nil }
        return resolved
    }

    struct AttachmentTarget: Equatable {
        let type: QuickBooksAttachableEntityType
        let id: String
    }

    /// A present invoice link has precedence, even while that record is still syncing.
    static func attachmentTarget(for call: ServiceCall, invoices: [Invoice], estimates: [Estimate], payments: [Payment]) -> AttachmentTarget? {
        if call.linkedInvoiceID != nil {
            guard let invoice = invoice(for: call, in: invoices, payments: payments),
                  let id = QuickBooksBillingIdentity.identifier(invoice.quickBooksID) else { return nil }
            return .init(type: .invoice, id: id)
        }
        if call.linkedEstimateID != nil {
            guard let estimate = estimate(for: call, in: estimates),
                  let id = QuickBooksBillingIdentity.identifier(estimate.quickBooksID) else { return nil }
            return .init(type: .estimate, id: id)
        }
        return nil
    }
}
