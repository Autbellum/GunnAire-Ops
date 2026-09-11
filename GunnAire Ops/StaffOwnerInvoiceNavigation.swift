import Foundation
import SwiftData

/// A navigation identity, not authority to replay an approval or publish a bill.
/// Keep the original company/session/customer/job; never fall back to a new invoice.
struct StaffOwnerInvoiceRoute: Identifiable {
    let context: StaffReplicaSourceContext
    let id: String
    let invoiceID: UUID
    let customerID: UUID
    let jobID: UUID?
    let customer: String

    init(review: StaffOwnerInvoiceReview, context: StaffReplicaSourceContext, customer: String) throws {
        try review.validate(context.scope)
        let origin = review.request.origin
        guard let invoice = UUID(uuidString: origin.invoiceID), let customerID = UUID(uuidString: origin.customerID),
              origin.jobID == nil || origin.jobID.flatMap(UUID.init(uuidString:)) != nil else {
            throw StaffOwnerInvoiceError.changed
        }
        self.context = context; id = review.id; invoiceID = invoice
        self.customerID = customerID; jobID = origin.jobID.flatMap(UUID.init(uuidString:)); self.customer = customer
    }

    @MainActor func resolve(invoices: [Invoice], customers: [Customer], jobs: [ServiceCall],
                            check: @MainActor (StaffReplicaSourceContext) throws -> Void) throws -> Invoice {
        try check(context)
        guard let invoice = BillingFocusedInvoicePolicy.resolve(invoiceID, in: invoices),
              customers.filter({ $0.id == customerID }).count == 1,
              let customer = customers.first(where: { $0.id == customerID }), invoice.customer === customer,
              invoice.serviceCallID == jobID else { throw StaffOwnerInvoiceError.missing }
        if let jobID {
            let matches = jobs.filter { $0.id == jobID }
            guard matches.count == 1, matches.first?.customer === customer else { throw StaffOwnerInvoiceError.changed }
        }
        try check(context)
        return invoice
    }
}

enum BillingFocusedInvoicePolicy {
    @MainActor static func resolve(_ id: UUID, in invoices: [Invoice]) -> Invoice? {
        let matches = invoices.filter { $0.id == id }
        return matches.count == 1 ? matches.first : nil
    }
}
