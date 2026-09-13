import Foundation
import SwiftData

/// Explicit owner-side values. These mappings are not staff role projections,
/// authorization, content delivery, or permission to activate a staff store.
extension StaffWorkspaceModelCodecs {
    static var agreement: StaffWorkspaceModelCodec<RecurringMaintenanceContract> {
        .init(kind: "agreement", id: \.id, fields: [
            .value("schedulePattern", \.schedulePattern),
            .value("nextDate", \.nextDate),
            .value("active", \.active),
            .value("renewalReminderDays", \.renewalReminderDays),
            .optional("planName", \.planName),
            .optional("termEndsOn", \.termEndsOn),
            .optional("pricePerVisit", \.pricePerVisit),
            .optional("includedVisitsPerTerm", \.includedVisitsPerTerm),
            .optional("coveredEquipmentIDsJSON", \.coveredEquipmentIDsJSON),
            .optional("lifecycleJSON", \.lifecycleJSON),
            .reference("customer", \.customer, id: \Customer.id, kind: "customer", required: true),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            RecurringMaintenanceContract(id: record.id, customer: try resolver.parent(Customer.self, kind: "customer", field: "customer", record: record), schedulePattern: "", nextDate: Date(timeIntervalSinceReferenceDate: 0), active: false)
        })
    }
    static var request: StaffWorkspaceModelCodec<ServiceRequest> {
        .init(kind: "request", id: \.id, fields: [
            .value("customerName", \.customerName),
            .value("requestedServiceTypeRaw", \.requestedServiceTypeRaw),
            .value("urgencyRaw", \.urgencyRaw),
            .value("summary", \.summary),
            .value("statusRaw", \.statusRaw),
            .value("createdAt", \.createdAt),
            .optional("backendRequestID", \.backendRequestID),
            .optional("phone", \.phone),
            .optional("email", \.email),
            .optional("address", \.address),
            .optional("preferredDate", \.preferredDate),
            .optional("qualificationNotes", \.qualificationNotes),
            .optional("createdByEmail", \.createdByEmail),
            .optional("qualifiedAt", \.qualifiedAt),
            .optional("convertedCustomerID", \.convertedCustomerID),
            .optional("convertedServiceCallID", \.convertedServiceCallID),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            ServiceRequest(id: record.id, customerName: "", summary: "")
        })
    }
    static var activity: StaffWorkspaceModelCodec<ServiceCallActivity> {
        .init(kind: "activity", id: \.id, fields: [
            .value("serviceCallID", \.serviceCallID),
            .value("action", \.action),
            .value("detail", \.detail),
            .value("occurredAt", \.occurredAt),
            .optional("actorEmail", \.actorEmail),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            ServiceCallActivity(id: record.id, serviceCallID: record.id, action: "", detail: "")
        })
    }
    static var milestone: StaffWorkspaceModelCodec<ProjectMilestone> {
        .init(kind: "milestone", id: \.id, fields: [
            .value("projectServiceCallID", \.projectServiceCallID),
            .value("estimateID", \.estimateID),
            .value("sequence", \.sequence),
            .value("title", \.title),
            .value("plannedDate", \.plannedDate),
            .value("billingPercent", \.billingPercent),
            .value("plannedAmount", \.plannedAmount),
            .value("billingTriggerRaw", \.billingTriggerRaw),
            .value("statusRaw", \.statusRaw),
            .value("createdAt", \.createdAt),
            .value("updatedAt", \.updatedAt),
            .optional("milestoneDescription", \.milestoneDescription),
            .optional("scheduledVisitID", \.scheduledVisitID),
            .optional("invoiceID", \.invoiceID),
            .optional("completedAt", \.completedAt),
            .optional("completedByEmail", \.completedByEmail),
            .optional("createdByEmail", \.createdByEmail),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            ProjectMilestone(id: record.id, projectServiceCallID: record.id, estimateID: record.id, sequence: 0, title: "", plannedDate: Date(timeIntervalSinceReferenceDate: 0), billingPercent: 0, plannedAmount: 0, billingTrigger: .milestoneCompletion)
        })
    }
    static var alert: StaffWorkspaceModelCodec<CustomerOperationalAlert> {
        .init(kind: "alert", id: \.id, fields: [
            .value("creationOperationID", \.creationOperationID),
            .value("customerID", \.customerID),
            .value("customerName", \.customerName),
            .value("kindRaw", \.kindRaw),
            .value("title", \.title),
            .value("createdAt", \.createdAt),
            .value("createdByEmail", \.createdByEmail),
            .value("updatedAt", \.updatedAt),
            .optional("serviceLocationID", \.serviceLocationID),
            .optional("serviceLocationName", \.serviceLocationName),
            .optional("detail", \.detail),
            .optional("resolvedAt", \.resolvedAt),
            .optional("resolvedByEmail", \.resolvedByEmail),
            .optional("resolutionNote", \.resolutionNote),
            .optional("resolutionOperationID", \.resolutionOperationID),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            CustomerOperationalAlert(id: record.id, customerID: record.id, customerName: "", kind: .other, title: "", createdByEmail: "")
        })
    }
    static var task: StaffWorkspaceModelCodec<BusinessTask> {
        .init(kind: "task", id: \.id, fields: [
            .value("creationOperationID", \.creationOperationID),
            .value("title", \.title),
            .value("priorityRaw", \.priorityRaw),
            .value("assignedToEmail", \.assignedToEmail),
            .value("dueAt", \.dueAt),
            .value("createdAt", \.createdAt),
            .value("createdByEmail", \.createdByEmail),
            .value("updatedAt", \.updatedAt),
            .optional("taskDescription", \.taskDescription),
            .optional("customerID", \.customerID),
            .optional("customerName", \.customerName),
            .optional("serviceLocationID", \.serviceLocationID),
            .optional("serviceLocationName", \.serviceLocationName),
            .optional("serviceCallID", \.serviceCallID),
            .optional("serviceCallSummary", \.serviceCallSummary),
            .optional("estimateID", \.estimateID),
            .optional("estimateSummary", \.estimateSummary),
            .optional("completedAt", \.completedAt),
            .optional("completedByEmail", \.completedByEmail),
            .optional("completionNote", \.completionNote),
            .optional("completionOperationID", \.completionOperationID),
            .optional("cancelledAt", \.cancelledAt),
            .optional("cancelledByEmail", \.cancelledByEmail),
            .optional("cancellationReason", \.cancellationReason),
            .optional("cancellationOperationID", \.cancellationOperationID),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            BusinessTask(id: record.id, title: "", assignedToEmail: "", dueAt: Date(timeIntervalSinceReferenceDate: 0), createdByEmail: "")
        })
    }
    static var taskEvent: StaffWorkspaceModelCodec<BusinessTaskEvent> {
        .init(kind: "taskEvent", id: \.id, fields: [
            .value("operationID", \.operationID),
            .value("taskID", \.taskID),
            .value("kindRaw", \.kindRaw),
            .value("occurredAt", \.occurredAt),
            .value("actorEmail", \.actorEmail),
            .value("detail", \.detail),
            .value("titleSnapshot", \.titleSnapshot),
            .value("assignedToEmailSnapshot", \.assignedToEmailSnapshot),
            .value("dueAtSnapshot", \.dueAtSnapshot),
            .value("priorityRawSnapshot", \.priorityRawSnapshot),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            BusinessTaskEvent(id: record.id, taskID: record.id, kind: .created, actorEmail: "", detail: "", titleSnapshot: "", assignedToEmailSnapshot: "", dueAtSnapshot: Date(timeIntervalSinceReferenceDate: 0), priority: .normal)
        })
    }
}
