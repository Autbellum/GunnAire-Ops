import Foundation
import SwiftData

/// Explicit owner-side values. These mappings are not staff role projections,
/// authorization, content delivery, or permission to activate a staff store.
extension StaffWorkspaceModelCodecs {
    static var user: StaffWorkspaceModelCodec<AppUser> {
        .init(kind: "user", id: \.id, fields: [
            .value("email", \.email),
            .value("roleRawValue", \.roleRawValue),
            .value("isActive", \.isActive),
            .value("createdAt", \.createdAt),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            AppUser(id: record.id, email: "", isActive: false)
        })
    }
    static var availability: StaffWorkspaceModelCodec<TechnicianAvailabilityBlock> {
        .init(kind: "availability", id: \.id, fields: [
            .value("creationOperationID", \.creationOperationID),
            .value("technicianID", \.technicianID),
            .value("startsAt", \.startsAt),
            .value("endsAt", \.endsAt),
            .value("kindRawValue", \.kindRawValue),
            .value("createdAt", \.createdAt),
            .value("createdByEmail", \.createdByEmail),
            .optional("reason", \.reason),
            .optional("sourceTimeOffRequestID", \.sourceTimeOffRequestID),
            .optional("cancelledAt", \.cancelledAt),
            .optional("cancelledByEmail", \.cancelledByEmail),
            .optional("cancellationReason", \.cancellationReason),
            .optional("cancellationOperationID", \.cancellationOperationID),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            TechnicianAvailabilityBlock(id: record.id, technicianID: record.id, startsAt: Date(timeIntervalSinceReferenceDate: 0), endsAt: Date(timeIntervalSinceReferenceDate: 0))
        })
    }
    static var shift: StaffWorkspaceModelCodec<TechnicianWorkShift> {
        .init(kind: "shift", id: \.id, fields: [
            .value("creationOperationID", \.creationOperationID),
            .value("technicianID", \.technicianID),
            .value("technicianNameSnapshot", \.technicianNameSnapshot),
            .value("weekdayRawValue", \.weekdayRawValue),
            .value("startMinute", \.startMinute),
            .value("durationMinutes", \.durationMinutes),
            .value("kindRawValue", \.kindRawValue),
            .value("effectiveFrom", \.effectiveFrom),
            .value("timeZoneIdentifier", \.timeZoneIdentifier),
            .value("createdAt", \.createdAt),
            .value("createdByEmail", \.createdByEmail),
            .optional("effectiveUntil", \.effectiveUntil),
            .optional("note", \.note),
            .optional("retiredAt", \.retiredAt),
            .optional("retiredByEmail", \.retiredByEmail),
            .optional("retirementReason", \.retirementReason),
            .optional("retirementOperationID", \.retirementOperationID),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            TechnicianWorkShift(id: record.id, technicianID: record.id, technicianNameSnapshot: "", weekday: .monday, startMinute: 0, durationMinutes: 1, kind: .regular, effectiveFrom: Date(timeIntervalSinceReferenceDate: 0), timeZoneIdentifier: "UTC", createdByEmail: "")
        })
    }
    static var timeOff: StaffWorkspaceModelCodec<TechnicianTimeOffRequest> {
        .init(kind: "timeOff", id: \.id, fields: [
            .value("creationOperationID", \.creationOperationID),
            .value("technicianID", \.technicianID),
            .value("technicianNameSnapshot", \.technicianNameSnapshot),
            .value("requestedByEmail", \.requestedByEmail),
            .value("startsAt", \.startsAt),
            .value("endsAt", \.endsAt),
            .value("createdAt", \.createdAt),
            .value("statusRawValue", \.statusRawValue),
            .value("updatedAt", \.updatedAt),
            .optional("privateReason", \.privateReason),
            .optional("reviewedAt", \.reviewedAt),
            .optional("reviewedByEmail", \.reviewedByEmail),
            .optional("privateReviewNote", \.privateReviewNote),
            .optional("reviewOperationID", \.reviewOperationID),
            .optional("approvedAvailabilityBlockID", \.approvedAvailabilityBlockID),
            .optional("withdrawnAt", \.withdrawnAt),
            .optional("withdrawnByEmail", \.withdrawnByEmail),
            .optional("withdrawalOperationID", \.withdrawalOperationID),
            .optional("cancelledAt", \.cancelledAt),
            .optional("cancelledByEmail", \.cancelledByEmail),
            .optional("cancellationReason", \.cancellationReason),
            .optional("cancellationOperationID", \.cancellationOperationID),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            TechnicianTimeOffRequest(id: record.id, technicianID: record.id, technicianNameSnapshot: "", requestedByEmail: "", startsAt: Date(timeIntervalSinceReferenceDate: 0), endsAt: Date(timeIntervalSinceReferenceDate: 0))
        })
    }
    static var availabilityEvent: StaffWorkspaceModelCodec<TechnicianAvailabilityEvent> {
        .init(kind: "availabilityEvent", id: \.id, fields: [
            .value("operationID", \.operationID),
            .value("kindRawValue", \.kindRawValue),
            .value("technicianID", \.technicianID),
            .value("technicianNameSnapshot", \.technicianNameSnapshot),
            .value("startsAt", \.startsAt),
            .value("endsAt", \.endsAt),
            .value("actorEmail", \.actorEmail),
            .value("occurredAt", \.occurredAt),
            .value("privateDetail", \.privateDetail),
            .optional("requestID", \.requestID),
            .optional("availabilityBlockID", \.availabilityBlockID),
            .optional("requestStatusRawSnapshot", \.requestStatusRawSnapshot),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            TechnicianAvailabilityEvent(id: record.id, requestID: nil, availabilityBlockID: nil, kind: .requested, technicianID: record.id, technicianNameSnapshot: "", startsAt: Date(timeIntervalSinceReferenceDate: 0), endsAt: Date(timeIntervalSinceReferenceDate: 0), actorEmail: "", privateDetail: "", requestStatus: nil)
        })
    }
    static var timeEntry: StaffWorkspaceModelCodec<TimeEntry> {
        .init(kind: "timeEntry", id: \.id, fields: [
            .value("userEmail", \.userEmail),
            .value("clockIn", \.clockIn),
            .value("reviewStatusRawValue", \.reviewStatusRawValue),
            .optional("clockOut", \.clockOut),
            .optional("notes", \.notes),
            .optional("quickBooksTimeActivityID", \.quickBooksTimeActivityID),
            .optional("quickBooksTimeActivitySyncToken", \.quickBooksTimeActivitySyncToken),
            .optional("quickBooksTimeActivitySyncedAt", \.quickBooksTimeActivitySyncedAt),
            .optional("quickBooksTimeActivitySyncError", \.quickBooksTimeActivitySyncError),
            .optional("reviewedByEmail", \.reviewedByEmail),
            .optional("reviewedAt", \.reviewedAt),
            .optional("reviewNote", \.reviewNote),
            .optional("reviewAuditJSON", \.reviewAuditJSON),
            .reference("serviceCall", \.serviceCall, id: \ServiceCall.id, kind: "job", required: false),
        ], excludedAttributes: [:], inverseRelationships: [], make: { record, resolver in
            TimeEntry(id: record.id, userEmail: "")
        })
    }
}
