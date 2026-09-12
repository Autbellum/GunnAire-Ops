import Foundation

@MainActor enum DocumentationQueueStatus: Equatable {
    case empty, current, pendingSync, review

    var message: String {
        switch self {
        case .empty: "No invoices are available in this view yet."
        case .current: "No invoices need closeout in this view."
        case .pendingSync: "Some billing records are still syncing. Payment and closeout status are not confirmed yet."
        case .review: "Some billing records need review. Open Invoices to check the original records."
        }
    }

    static func resolve(invoices: [Invoice], payments: [Payment], visibleCalls: [ServiceCall], includesAllInvoices: Bool) -> Self {
        let callIDs = Set(visibleCalls.map(\.id))
        let linkedIDs = Set(visibleCalls.compactMap(\.linkedInvoiceID))
        let scoped = invoices.filter { includesAllInvoices || linkedIDs.contains($0.id) || $0.serviceCallID.map(callIDs.contains) == true }
        if scoped.contains(where: { $0.customer == nil }) ||
            visibleCalls.contains(where: { $0.linkedInvoiceID != nil && $0.customer == nil }) ||
            linkedIDs.contains(where: { id in !invoices.contains { $0.id == id } }) ||
            (includesAllInvoices && payments.contains { $0.invoice == nil }) {
            return .pendingSync
        }
        if visibleCalls.contains(where: { call in
            call.linkedInvoiceID != nil && JobBillingDocumentLinks.invoice(for: call, in: invoices, payments: payments) == nil
        }) { return .review }
        let projection = BillingMilestoneReconciliation.project(scoped, payments: payments)
        if projection.needsReview || projection.activeInvoices.contains(where: { $0.quickBooksReconciliationReviewMessage != nil }) {
            return .review
        }
        return scoped.isEmpty ? .empty : .current
    }
}
