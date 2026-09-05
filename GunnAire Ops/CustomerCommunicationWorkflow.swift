import Foundation
import SwiftData

/// Applies operational changes only after the mail provider confirms delivery.
/// Draft creation, cancellation, and provider failures intentionally do nothing.
enum CustomerCommunicationWorkflow {
    @MainActor
    static func contextIsValid(
        workflow: GunnAireMailWorkflow,
        customerID: UUID?,
        serviceCallID: UUID?,
        invoiceID: UUID?,
        estimateID: UUID?,
        maintenanceContractID: UUID?,
        estimates: [Estimate],
        invoices: [Invoice],
        serviceCalls: [ServiceCall],
        recurringContracts: [RecurringMaintenanceContract]
    ) -> Bool {
        guard let customerID else { return false }

        switch workflow {
        case .general:
            return true

        case .estimateFollowUp:
            guard let estimateID,
                  let estimate = estimates.first(where: { $0.id == estimateID && $0.customer.id == customerID }) else {
                return false
            }
            let status = estimate.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return status == "pending" || status == "follow-up"

        case .paymentReminder:
            guard let invoiceID,
                  let invoice = invoices.first(where: { $0.id == invoiceID && $0.customer.id == customerID }) else {
                return false
            }
            return invoice.normalizedStatus != "paid"

        case .appointmentConfirmation, .technicianEnRoute, .technicianArrival,
             .workInProgress, .serviceFollowUp, .postJobReview:
            guard let serviceCallID,
                  let call = serviceCalls.first(where: { $0.id == serviceCallID && $0.customer.id == customerID }) else {
                return false
            }
            if workflow == .postJobReview {
                return call.isEligibleForReviewRequest
            }
            return call.status != .cancelled

        case .maintenanceVisitReminder, .maintenanceRenewal:
            guard let maintenanceContractID else { return false }
            return recurringContracts.contains {
                $0.id == maintenanceContractID && $0.customer.id == customerID && $0.active
            }

        case .receipt:
            guard let invoiceID else { return false }
            return invoices.contains { $0.id == invoiceID && $0.customer.id == customerID }

        case .customerDocument:
            let invoiceMatches = invoiceID.map { id in
                invoices.contains { $0.id == id && $0.customer.id == customerID }
            } ?? false
            let estimateMatches = estimateID.map { id in
                estimates.contains { $0.id == id && $0.customer.id == customerID }
            } ?? false
            let callMatches = serviceCallID.map { id in
                serviceCalls.contains { $0.id == id && $0.customer.id == customerID }
            } ?? false
            return invoiceMatches || estimateMatches || callMatches

        case .accountStatement:
            return invoices.contains { $0.customer.id == customerID }
        }
    }

    @MainActor
    @discardableResult
    static func applyConfirmedSend(
        workflow: GunnAireMailWorkflow,
        customerID: UUID?,
        serviceCallID: UUID?,
        invoiceID: UUID?,
        estimateID: UUID?,
        maintenanceContractID: UUID? = nil,
        estimates: [Estimate],
        invoices: [Invoice],
        serviceCalls: [ServiceCall],
        recurringContracts: [RecurringMaintenanceContract] = [],
        now: Date = Date(),
        actorEmail: String?,
        deliveryEvidenceText: String = "Gmail confirmed delivery",
        in modelContext: ModelContext
    ) -> Bool {
        guard let customerID,
              contextIsValid(
                workflow: workflow,
                customerID: customerID,
                serviceCallID: serviceCallID,
                invoiceID: invoiceID,
                estimateID: estimateID,
                maintenanceContractID: maintenanceContractID,
                estimates: estimates,
                invoices: invoices,
                serviceCalls: serviceCalls,
                recurringContracts: recurringContracts
              ) else { return false }

        switch workflow {
        case .general:
            return true

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
                    detail: "\(deliveryEvidenceText); the next estimate follow-up is due in 3 days.",
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
                detail: "\(deliveryEvidenceText); payment follow-up is due in 1 day.",
                actorEmail: actorEmail,
                in: modelContext
            )
            return true

        case .appointmentConfirmation, .technicianEnRoute, .technicianArrival, .workInProgress:
            guard let serviceCallID,
                  let linkedCall = serviceCalls.first(where: { $0.id == serviceCallID && $0.customer.id == customerID }) else {
                return false
            }
            ServiceCallActivity.record(
                for: linkedCall,
                action: workflow.displayName + " sent",
                detail: "\(deliveryEvidenceText) for template \(workflow.templateVersion).",
                actorEmail: actorEmail,
                in: modelContext
            )
            return true

        case .serviceFollowUp:
            guard let serviceCallID,
                  let linkedCall = serviceCalls.first(where: { $0.id == serviceCallID && $0.customer.id == customerID }) else {
                return false
            }
            linkedCall.followUpRequired = true
            if linkedCall.followUpAction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                linkedCall.followUpAction = "Follow up with customer"
            }
            linkedCall.followUpDueDate = Calendar.current.date(byAdding: .day, value: 3, to: now)
            ServiceCallActivity.record(
                for: linkedCall,
                action: "Service follow-up sent",
                detail: "\(deliveryEvidenceText); the next customer follow-up is due in 3 days.",
                actorEmail: actorEmail,
                in: modelContext
            )
            return true

        case .postJobReview:
            guard let serviceCallID,
                  let linkedCall = serviceCalls.first(where: { $0.id == serviceCallID && $0.customer.id == customerID }) else {
                return false
            }
            ServiceCallActivity.record(
                for: linkedCall,
                action: "Review request sent",
                detail: "\(deliveryEvidenceText) after the customer's marketing preference was checked.",
                actorEmail: actorEmail,
                in: modelContext
            )
            return true

        case .maintenanceVisitReminder, .maintenanceRenewal:
            return recurringContracts.contains {
                $0.id == maintenanceContractID && $0.customer.id == customerID && $0.active
            }

        case .receipt, .customerDocument, .accountStatement:
            return true
        }
    }
}
