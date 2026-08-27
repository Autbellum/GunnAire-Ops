import Foundation
import SwiftData

/// Applies operational changes only after the mail provider confirms delivery.
/// Draft creation, cancellation, and provider failures intentionally do nothing.
enum CustomerCommunicationWorkflow {
    @MainActor
    @discardableResult
    static func applyConfirmedSend(
        workflow: GunnAireMailWorkflow,
        customerID: UUID?,
        serviceCallID: UUID?,
        invoiceID: UUID?,
        estimateID: UUID?,
        estimates: [Estimate],
        invoices: [Invoice],
        serviceCalls: [ServiceCall],
        now: Date = Date(),
        actorEmail: String?,
        in modelContext: ModelContext
    ) -> Bool {
        guard let customerID else { return false }

        switch workflow {
        case .general:
            return false

        case .estimateFollowUp:
            guard let estimateID,
                  let estimate = estimates.first(where: { $0.id == estimateID && $0.customer.id == customerID }) else {
                return false
            }
            let normalizedStatus = estimate.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedStatus == "pending" || normalizedStatus == "follow-up" else { return false }

            let linkedCallID = serviceCallID ?? estimate.serviceCallID
            let linkedCall = linkedCallID.flatMap { id in
                serviceCalls.first { $0.id == id && $0.customer.id == customerID }
            }
            if serviceCallID != nil, linkedCall == nil { return false }

            estimate.status = "follow-up"
            if let linkedCall {
                linkedCall.followUpRequired = true
                linkedCall.followUpAction = "Follow up on estimate"
                linkedCall.followUpDueDate = Calendar.current.date(byAdding: .day, value: 3, to: now)
                ServiceCallActivity.record(
                    for: linkedCall,
                    action: "Estimate follow-up sent",
                    detail: "Gmail confirmed delivery; the next estimate follow-up is due in 3 days.",
                    actorEmail: actorEmail,
                    in: modelContext
                )
            }
            return true

        case .paymentReminder:
            guard let invoiceID,
                  let invoice = invoices.first(where: { $0.id == invoiceID && $0.customer.id == customerID }),
                  invoice.normalizedStatus != "paid" else {
                return false
            }

            let linkedCallID = serviceCallID ?? invoice.serviceCallID
            guard let linkedCallID,
                  let linkedCall = serviceCalls.first(where: { $0.id == linkedCallID && $0.customer.id == customerID }) else {
                return false
            }
            linkedCall.followUpRequired = true
            linkedCall.followUpAction = "Collect payment"
            linkedCall.followUpDueDate = Calendar.current.date(byAdding: .day, value: 1, to: now)
            ServiceCallActivity.record(
                for: linkedCall,
                action: "Payment reminder sent",
                detail: "Gmail confirmed delivery; payment follow-up is due in 1 day.",
                actorEmail: actorEmail,
                in: modelContext
            )
            return true
        }
    }
}
